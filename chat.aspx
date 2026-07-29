<%@ Page Language="C#" AutoEventWireup="true" %>
<%@ Import Namespace="System" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Text" %>
<%@ Import Namespace="System.Web" %>
<%@ Import Namespace="System.Web.UI" %>
<%@ Import Namespace="System.Runtime.InteropServices" %>
<%@ Import Namespace="System.Globalization" %>

<script runat="server">
    // ============================================================
    // LAN内 iPad向け 写真共有ページ
    // 対象: IIS + ASP.NET Web Forms (.NET Framework 4.8 推奨)
    // DB  : Windows標準 winsqlite3.dll
    // ============================================================

    private const int SQLITE_OK = 0;
    private const int SQLITE_BUSY = 5;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_DONE = 101;

    private const int SQLITE_OPEN_READWRITE = 0x00000002;
    private const int SQLITE_OPEN_CREATE = 0x00000004;
    private const int SQLITE_OPEN_FULLMUTEX = 0x00010000;

    private const int MAX_FILE_SIZE = 15 * 1024 * 1024; // 15MB
    private const int BUSY_TIMEOUT_MS = 5000;

    private static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);
    private static readonly object DatabaseInitLock = new object();
    private static readonly object CleanupLock = new object();
    private static bool databaseInitialized = false;
    private static DateTime lastCleanupDate = DateTime.MinValue;

    private string dbPath;
    private bool requestHandled;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open_v2(
        byte[] filename,
        out IntPtr db,
        int flags,
        IntPtr zVfs
    );

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(
        IntPtr db,
        string sql,
        IntPtr callback,
        IntPtr arg,
        out IntPtr errmsg
    );

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void sqlite3_free(IntPtr ptr);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_errmsg(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(
        IntPtr db,
        string sql,
        int numBytes,
        out IntPtr stmt,
        IntPtr tail
    );

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_blob(
        IntPtr stmt,
        int index,
        byte[] value,
        int numBytes,
        IntPtr destructor
    );

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(
        IntPtr stmt,
        int index,
        byte[] value,
        int numBytes,
        IntPtr destructor
    );

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_int64(IntPtr stmt, int index, long value);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_blob(IntPtr stmt, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(IntPtr stmt, int column);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr stmt, int column);

    protected void Page_Load(object sender, EventArgs e)
    {
        try
        {
            string appDataPath = Server.MapPath("~/App_Data");
            Directory.CreateDirectory(appDataPath);
            dbPath = Path.Combine(appDataPath, "photo_share.db");

            EnsureDatabase();
            CleanupOldFilesOncePerDay();

            string token = Request.QueryString["token"];

            if (string.Equals(Request.HttpMethod, "GET", StringComparison.OrdinalIgnoreCase)
                && !string.IsNullOrWhiteSpace(token))
            {
                requestHandled = true;
                ServeFile(token);
                CompleteRequest();
                return;
            }

            if (string.Equals(Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
            {
                requestHandled = true;
                HandleFileUpload();
                CompleteRequest();
                return;
            }
        }
        catch (DllNotFoundException)
        {
            requestHandled = true;
            WriteJsonError(500, "winsqlite3.dllを読み込めません。対応するWindows環境で実行してください。");
            CompleteRequest();
        }
        catch (BadImageFormatException)
        {
            requestHandled = true;
            WriteJsonError(500, "winsqlite3.dllの32bit/64bit構成がIISと一致していません。");
            CompleteRequest();
        }
        catch (Exception ex)
        {
            requestHandled = true;
            LogError(ex);
            WriteJsonError(500, "サーバーの初期化に失敗しました。");
            CompleteRequest();
        }
    }

    // CompleteRequestだけでは通常のページ描画を止めないため、
    // JSONまたは画像を返した要求ではHTMLを追加出力しない。
    protected override void Render(HtmlTextWriter writer)
    {
        if (!requestHandled)
        {
            base.Render(writer);
        }
    }

    private void CompleteRequest()
    {
        Context.ApplicationInstance.CompleteRequest();
    }

    private IntPtr OpenDatabase()
    {
        IntPtr db = IntPtr.Zero;
        byte[] pathBytes = Utf8NullTerminated(dbPath);

        int result = sqlite3_open_v2(
            pathBytes,
            out db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            IntPtr.Zero
        );

        if (result != SQLITE_OK)
        {
            string detail = db == IntPtr.Zero ? "DBハンドルを取得できませんでした。" : GetSqliteError(db);
            if (db != IntPtr.Zero)
            {
                sqlite3_close(db);
            }
            throw new InvalidOperationException("SQLiteデータベースを開けません。" + detail + " (code=" + result + ")");
        }

        int timeoutResult = sqlite3_busy_timeout(db, BUSY_TIMEOUT_MS);
        if (timeoutResult != SQLITE_OK)
        {
            string detail = GetSqliteError(db);
            sqlite3_close(db);
            throw new InvalidOperationException("SQLite busy_timeoutの設定に失敗しました。" + detail);
        }

        return db;
    }

    private void EnsureDatabase()
    {
        if (databaseInitialized)
        {
            return;
        }

        lock (DatabaseInitLock)
        {
            if (databaseInitialized)
            {
                return;
            }

            IntPtr db = IntPtr.Zero;
            try
            {
                db = OpenDatabase();

                ExecuteSql(db, "PRAGMA journal_mode=WAL;");
                ExecuteSql(db, "PRAGMA synchronous=NORMAL;");

                ExecuteSql(
                    db,
                    "CREATE TABLE IF NOT EXISTS PhotoFiles (" +
                    "id INTEGER PRIMARY KEY AUTOINCREMENT," +
                    "public_token TEXT NOT NULL UNIQUE," +
                    "filename TEXT NOT NULL," +
                    "content_type TEXT NOT NULL," +
                    "file_data BLOB NOT NULL," +
                    "created_at INTEGER NOT NULL" +
                    ");"
                );

                ExecuteSql(
                    db,
                    "CREATE INDEX IF NOT EXISTS IX_PhotoFiles_CreatedAt " +
                    "ON PhotoFiles(created_at);"
                );

                databaseInitialized = true;
            }
            finally
            {
                if (db != IntPtr.Zero)
                {
                    sqlite3_close(db);
                }
            }
        }
    }

    private void CleanupOldFilesOncePerDay()
    {
        DateTime today = DateTime.Today;
        if (lastCleanupDate == today)
        {
            return;
        }

        lock (CleanupLock)
        {
            if (lastCleanupDate == today)
            {
                return;
            }

            IntPtr db = IntPtr.Zero;
            IntPtr stmt = IntPtr.Zero;

            try
            {
                db = OpenDatabase();

                // 当日00:00より前を削除する。
                long cutoff = ToUnixTimeSeconds(today);
                const string sql = "DELETE FROM PhotoFiles WHERE created_at < ?;";

                CheckSqlite(
                    sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero),
                    db,
                    "古い画像削除の準備"
                );

                CheckSqlite(
                    sqlite3_bind_int64(stmt, 1, cutoff),
                    db,
                    "削除基準日時の設定"
                );

                int stepResult = sqlite3_step(stmt);
                if (stepResult != SQLITE_DONE)
                {
                    throw new InvalidOperationException(
                        "古い画像の削除に失敗しました。" + GetSqliteError(db) +
                        " (code=" + stepResult + ")"
                    );
                }

                lastCleanupDate = today;
            }
            catch (Exception ex)
            {
                // 清掃失敗で本体機能を停止させない。
                LogError(ex);
            }
            finally
            {
                if (stmt != IntPtr.Zero)
                {
                    sqlite3_finalize(stmt);
                }
                if (db != IntPtr.Zero)
                {
                    sqlite3_close(db);
                }
            }
        }
    }

    private void HandleFileUpload()
    {
        Response.Clear();
        Response.ContentType = "application/json; charset=utf-8";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);
        Response.Cache.SetNoStore();
        Response.TrySkipIisCustomErrors = true;
        Response.AddHeader("X-Content-Type-Options", "nosniff");

        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;

        try
        {
            if (Request.Files.Count == 0)
            {
                WriteJsonError(400, "ファイルが送信されていません。");
                return;
            }

            HttpPostedFile file = Request.Files["file"];
            if (file == null)
            {
                file = Request.Files[0];
            }

            if (file == null || file.ContentLength <= 0)
            {
                WriteJsonError(400, "ファイルデータが空です。");
                return;
            }

            if (file.ContentLength > MAX_FILE_SIZE)
            {
                WriteJsonError(413, "画像は15MB以下にしてください。");
                return;
            }

            byte[] fileBytes = ReadAllBytes(file.InputStream, MAX_FILE_SIZE);
            string detectedContentType = DetectImageContentType(fileBytes);

            if (detectedContentType == null)
            {
                WriteJsonError(415, "JPEGまたはPNG画像のみ送信できます。");
                return;
            }

            string originalName = Path.GetFileName(file.FileName ?? string.Empty);
            if (string.IsNullOrWhiteSpace(originalName))
            {
                originalName = detectedContentType == "image/png" ? "image.png" : "image.jpg";
            }

            // 極端に長いファイル名を保存しない。
            if (originalName.Length > 255)
            {
                string extension = detectedContentType == "image/png" ? ".png" : ".jpg";
                originalName = originalName.Substring(0, 240) + extension;
            }

            string publicToken = Guid.NewGuid().ToString("N");
            long createdAt = ToUnixTimeSeconds(DateTime.Now);

            db = OpenDatabase();

            const string sql =
                "INSERT INTO PhotoFiles " +
                "(public_token, filename, content_type, file_data, created_at) " +
                "VALUES (?, ?, ?, ?, ?);";

            CheckSqlite(
                sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero),
                db,
                "画像保存処理の準備"
            );

            BindText(stmt, 1, publicToken, db, "公開トークン");
            BindText(stmt, 2, originalName, db, "ファイル名");
            BindText(stmt, 3, detectedContentType, db, "画像形式");

            CheckSqlite(
                sqlite3_bind_blob(stmt, 4, fileBytes, fileBytes.Length, SQLITE_TRANSIENT),
                db,
                "画像データの設定"
            );

            CheckSqlite(
                sqlite3_bind_int64(stmt, 5, createdAt),
                db,
                "保存日時の設定"
            );

            int stepResult = sqlite3_step(stmt);
            if (stepResult != SQLITE_DONE)
            {
                string busyText = stepResult == SQLITE_BUSY ? "データベースが使用中です。少し待って再試行してください。" : string.Empty;
                throw new InvalidOperationException(
                    "画像を保存できませんでした。" + busyText + GetSqliteError(db) +
                    " (code=" + stepResult + ")"
                );
            }

            string fileUrl = BuildFileUrl(publicToken);

            Response.StatusCode = 200;
            Response.Write(
                "{\"success\":true," +
                "\"fileName\":\"" + JsonEscape(originalName) + "\"," +
                "\"fileUrl\":\"" + JsonEscape(fileUrl) + "\"}"
            );
        }
        catch (Exception ex)
        {
            LogError(ex);
            WriteJsonError(500, "画像の保存に失敗しました。");
        }
        finally
        {
            if (stmt != IntPtr.Zero)
            {
                sqlite3_finalize(stmt);
            }
            if (db != IntPtr.Zero)
            {
                sqlite3_close(db);
            }
        }
    }

    private void ServeFile(string token)
    {
        Response.Clear();
        Response.TrySkipIisCustomErrors = true;
        Response.AddHeader("X-Content-Type-Options", "nosniff");

        if (!IsValidToken(token))
        {
            SendTextError(404, "画像が見つかりません。");
            return;
        }

        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;

        try
        {
            db = OpenDatabase();

            const string sql =
                "SELECT filename, content_type, file_data " +
                "FROM PhotoFiles WHERE public_token = ? LIMIT 1;";

            CheckSqlite(
                sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero),
                db,
                "画像読込処理の準備"
            );

            BindText(stmt, 1, token, db, "公開トークン");

            int stepResult = sqlite3_step(stmt);
            if (stepResult != SQLITE_ROW)
            {
                SendTextError(404, "画像が見つかりません。");
                return;
            }

            string filename = ReadSqliteText(stmt, 0);
            string contentType = ReadSqliteText(stmt, 1);
            byte[] fileData = ReadSqliteBlob(stmt, 2);

            if (fileData == null || fileData.Length == 0)
            {
                SendTextError(404, "画像が見つかりません。");
                return;
            }

            if (contentType != "image/jpeg" && contentType != "image/png")
            {
                SendTextError(415, "対応していない画像形式です。");
                return;
            }

            Response.StatusCode = 200;
            Response.ContentType = contentType;
            Response.Cache.SetCacheability(HttpCacheability.Private);
            Response.Cache.SetMaxAge(TimeSpan.FromMinutes(10));
            Response.AddHeader("Content-Disposition", "inline; filename*=UTF-8''" + Uri.EscapeDataString(filename));
            Response.AddHeader("Content-Length", fileData.Length.ToString(CultureInfo.InvariantCulture));
            Response.OutputStream.Write(fileData, 0, fileData.Length);
        }
        catch (Exception ex)
        {
            LogError(ex);
            SendTextError(500, "画像を読み込めませんでした。");
        }
        finally
        {
            if (stmt != IntPtr.Zero)
            {
                sqlite3_finalize(stmt);
            }
            if (db != IntPtr.Zero)
            {
                sqlite3_close(db);
            }
        }
    }

    private void ExecuteSql(IntPtr db, string sql)
    {
        IntPtr errorMessage = IntPtr.Zero;
        int result = sqlite3_exec(db, sql, IntPtr.Zero, IntPtr.Zero, out errorMessage);

        try
        {
            if (result != SQLITE_OK)
            {
                string message = errorMessage == IntPtr.Zero
                    ? GetSqliteError(db)
                    : ReadUtf8Pointer(errorMessage, -1);

                throw new InvalidOperationException(
                    "SQLite SQL実行エラー: " + message + " (code=" + result + ")"
                );
            }
        }
        finally
        {
            if (errorMessage != IntPtr.Zero)
            {
                sqlite3_free(errorMessage);
            }
        }
    }

    private void BindText(IntPtr stmt, int index, string value, IntPtr db, string operation)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(value ?? string.Empty);
        CheckSqlite(
            sqlite3_bind_text(stmt, index, bytes, bytes.Length, SQLITE_TRANSIENT),
            db,
            operation + "の設定"
        );
    }

    private void CheckSqlite(int result, IntPtr db, string operation)
    {
        if (result != SQLITE_OK)
        {
            throw new InvalidOperationException(
                operation + "に失敗しました。" + GetSqliteError(db) +
                " (code=" + result + ")"
            );
        }
    }

    private string GetSqliteError(IntPtr db)
    {
        if (db == IntPtr.Zero)
        {
            return "SQLiteハンドルがありません。";
        }

        IntPtr ptr = sqlite3_errmsg(db);
        return ptr == IntPtr.Zero ? "不明なSQLiteエラー" : ReadUtf8Pointer(ptr, -1);
    }

    private string ReadSqliteText(IntPtr stmt, int column)
    {
        IntPtr ptr = sqlite3_column_text(stmt, column);
        int length = sqlite3_column_bytes(stmt, column);

        if (ptr == IntPtr.Zero || length <= 0)
        {
            return string.Empty;
        }

        return ReadUtf8Pointer(ptr, length);
    }

    private byte[] ReadSqliteBlob(IntPtr stmt, int column)
    {
        int length = sqlite3_column_bytes(stmt, column);
        if (length <= 0)
        {
            return new byte[0];
        }

        IntPtr ptr = sqlite3_column_blob(stmt, column);
        if (ptr == IntPtr.Zero)
        {
            return null;
        }

        byte[] data = new byte[length];
        Marshal.Copy(ptr, data, 0, length);
        return data;
    }

    private string ReadUtf8Pointer(IntPtr ptr, int knownLength)
    {
        int length = knownLength;

        if (length < 0)
        {
            length = 0;
            while (Marshal.ReadByte(ptr, length) != 0)
            {
                length++;
            }
        }

        if (length == 0)
        {
            return string.Empty;
        }

        byte[] bytes = new byte[length];
        Marshal.Copy(ptr, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }

    private byte[] Utf8NullTerminated(string value)
    {
        byte[] text = Encoding.UTF8.GetBytes(value);
        byte[] result = new byte[text.Length + 1];
        Buffer.BlockCopy(text, 0, result, 0, text.Length);
        result[result.Length - 1] = 0;
        return result;
    }

    private byte[] ReadAllBytes(Stream input, int maxBytes)
    {
        using (MemoryStream output = new MemoryStream())
        {
            byte[] buffer = new byte[81920];
            int total = 0;
            int read;

            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                total += read;
                if (total > maxBytes)
                {
                    throw new InvalidOperationException("ファイルサイズが上限を超えています。");
                }
                output.Write(buffer, 0, read);
            }

            return output.ToArray();
        }
    }

    private string DetectImageContentType(byte[] data)
    {
        if (data == null || data.Length < 8)
        {
            return null;
        }

        if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
        {
            return "image/jpeg";
        }

        if (data[0] == 0x89 &&
            data[1] == 0x50 &&
            data[2] == 0x4E &&
            data[3] == 0x47 &&
            data[4] == 0x0D &&
            data[5] == 0x0A &&
            data[6] == 0x1A &&
            data[7] == 0x0A)
        {
            return "image/png";
        }

        return null;
    }

    private bool IsValidToken(string token)
    {
        if (string.IsNullOrEmpty(token) || token.Length != 32)
        {
            return false;
        }

        for (int i = 0; i < token.Length; i++)
        {
            char c = token[i];
            bool isHex =
                (c >= '0' && c <= '9') ||
                (c >= 'a' && c <= 'f') ||
                (c >= 'A' && c <= 'F');

            if (!isHex)
            {
                return false;
            }
        }

        return true;
    }

    private string BuildFileUrl(string token)
    {
        string path = Request.Url.AbsolutePath;
        return path + "?token=" + HttpUtility.UrlEncode(token);
    }

    private long ToUnixTimeSeconds(DateTime localDateTime)
    {
        DateTimeOffset dto = new DateTimeOffset(localDateTime);
        return dto.ToUnixTimeSeconds();
    }

    private string JsonEscape(string value)
    {
        return HttpUtility.JavaScriptStringEncode(value ?? string.Empty);
    }

    private void WriteJsonError(int statusCode, string message)
    {
        Response.Clear();
        Response.StatusCode = statusCode;
        Response.TrySkipIisCustomErrors = true;
        Response.ContentType = "application/json; charset=utf-8";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);
        Response.Cache.SetNoStore();
        Response.AddHeader("X-Content-Type-Options", "nosniff");
        Response.Write(
            "{\"success\":false,\"message\":\"" + JsonEscape(message) + "\"}"
        );
    }

    private void SendTextError(int statusCode, string message)
    {
        Response.Clear();
        Response.StatusCode = statusCode;
        Response.TrySkipIisCustomErrors = true;
        Response.ContentType = "text/plain; charset=utf-8";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);
        Response.Cache.SetNoStore();
        Response.AddHeader("X-Content-Type-Options", "nosniff");
        Response.Write(message);
    }

    private void LogError(Exception ex)
    {
        try
        {
            string appDataPath = Server.MapPath("~/App_Data");
            Directory.CreateDirectory(appDataPath);
            string logPath = Path.Combine(appDataPath, "photo_share_error.log");
            string line =
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) +
                "\t" + ex.ToString() + Environment.NewLine;
            File.AppendAllText(logPath, line, Encoding.UTF8);
        }
        catch
        {
            // ログ書込み失敗を利用者への応答に波及させない。
        }
    }
</script>

<!DOCTYPE html>
<html lang="ja">
<head runat="server">
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover" />
    <title>写真共有</title>
    <style>
        * {
            box-sizing: border-box;
            -webkit-tap-highlight-color: transparent;
        }

        html, body {
            min-height: 100%;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
            background-color: #f2f2f7;
            color: #1c1c1e;
            margin: 0;
            padding: calc(20px + env(safe-area-inset-top)) 16px calc(20px + env(safe-area-inset-bottom));
            display: flex;
            justify-content: center;
            align-items: flex-start;
            min-height: 100vh;
        }

        .upload-card {
            background: #ffffff;
            width: 100%;
            max-width: 500px;
            padding: 24px;
            border-radius: 16px;
            box-shadow: 0 4px 20px rgba(0, 0, 0, 0.06);
        }

        h1 {
            margin: 0 0 20px 0;
            font-size: 1.25rem;
            font-weight: 700;
            text-align: center;
        }

        .action-group {
            display: flex;
            flex-direction: column;
            gap: 12px;
            margin-bottom: 20px;
        }

        .btn-touch {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            width: 100%;
            min-height: 54px;
            padding: 10px 14px;
            border-radius: 12px;
            font-size: 1.05rem;
            font-weight: 600;
            border: none;
            cursor: pointer;
            touch-action: manipulation;
            transition: opacity 0.2s, transform 0.1s;
        }

        .btn-touch:active {
            opacity: 0.75;
            transform: scale(0.98);
        }

        .btn-touch:disabled {
            opacity: 0.5;
            cursor: default;
            transform: none;
        }

        .btn-camera {
            background-color: #007aff;
            color: #ffffff;
        }

        .btn-library {
            background-color: #e5e5ea;
            color: #007aff;
        }

        .file-input {
            display: none;
        }

        #resultArea {
            margin-top: 15px;
        }

        .status-msg {
            padding: 14px;
            border-radius: 10px;
            font-size: 0.95rem;
            text-align: center;
            font-weight: 500;
            overflow-wrap: anywhere;
        }

        .status-msg.success { background: #d1e7dd; color: #0f5132; }
        .status-msg.error { background: #f8d7da; color: #842029; }
        .status-msg.info { background: #e2e3e5; color: #41464b; }

        .preview-container {
            margin-top: 15px;
            text-align: center;
        }

        .preview-img {
            display: block;
            width: auto;
            max-width: 100%;
            max-height: 60vh;
            margin: 0 auto;
            border-radius: 12px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            object-fit: contain;
        }

        .note {
            margin: 14px 0 0;
            color: #6e6e73;
            font-size: 0.82rem;
            line-height: 1.5;
            text-align: center;
        }
    </style>
</head>
<body>
    <main class="upload-card">
        <h1>写真共有</h1>

        <div class="action-group">
            <button type="button" class="btn-touch btn-camera" id="cameraButton">
                📷 その場で写真を撮影
            </button>

            <button type="button" class="btn-touch btn-library" id="libraryButton">
                🖼️ アルバムから選択
            </button>

            <input type="file" id="cameraInput" class="file-input" accept="image/jpeg,image/png" capture="environment" />
            <input type="file" id="libraryInput" class="file-input" accept="image/jpeg,image/png" />
        </div>

        <div id="resultArea" aria-live="polite"></div>
        <p class="note">JPEG・PNG、15MB以下。画像は翌日になると自動削除されます。</p>
    </main>

    <script>
        (function () {
            'use strict';

            var cameraInput = document.getElementById('cameraInput');
            var libraryInput = document.getElementById('libraryInput');
            var cameraButton = document.getElementById('cameraButton');
            var libraryButton = document.getElementById('libraryButton');
            var resultArea = document.getElementById('resultArea');
            var uploading = false;
            var maxFileSize = 15 * 1024 * 1024;

            cameraButton.addEventListener('click', function () {
                if (!uploading) {
                    cameraInput.click();
                }
            });

            libraryButton.addEventListener('click', function () {
                if (!uploading) {
                    libraryInput.click();
                }
            });

            cameraInput.addEventListener('change', function () {
                handleFileSelect(cameraInput);
            });

            libraryInput.addEventListener('change', function () {
                handleFileSelect(libraryInput);
            });

            function handleFileSelect(inputElement) {
                if (inputElement.files && inputElement.files.length > 0) {
                    uploadFile(inputElement.files[0]);
                }
            }

            function uploadFile(file) {
                if (uploading || !file) {
                    return;
                }

                if (file.size <= 0) {
                    showStatus('ファイルデータが空です。', 'error');
                    resetInputs();
                    return;
                }

                if (file.size > maxFileSize) {
                    showStatus('画像は15MB以下にしてください。', 'error');
                    resetInputs();
                    return;
                }

                uploading = true;
                setButtonsDisabled(true);
                showStatus('SQLiteへ保存中...', 'info');

                var formData = new FormData();
                formData.append('file', file, file.name || 'image.jpg');

                fetch(window.location.pathname, {
                    method: 'POST',
                    body: formData,
                    credentials: 'same-origin',
                    cache: 'no-store'
                })
                .then(function (response) {
                    return response.text().then(function (text) {
                        var data;
                        try {
                            data = JSON.parse(text);
                        } catch (parseError) {
                            throw new Error('サーバーから正しい応答が返されませんでした。');
                        }

                        if (!response.ok || !data.success) {
                            throw new Error(data.message || '保存に失敗しました。');
                        }

                        return data;
                    });
                })
                .then(function (data) {
                    showSuccess(data.fileUrl);
                })
                .catch(function (error) {
                    if (window.console && console.error) {
                        console.error('Upload Error:', error);
                    }
                    showStatus(error.message || '送信中にエラーが発生しました。', 'error');
                })
                .then(function () {
                    uploading = false;
                    setButtonsDisabled(false);
                    resetInputs();
                });
            }

            function showSuccess(fileUrl) {
                clearResultArea();

                var status = document.createElement('div');
                status.className = 'status-msg success';
                status.textContent = 'SQLiteデータベースへ保存しました。';

                var previewContainer = document.createElement('div');
                previewContainer.className = 'preview-container';

                var image = document.createElement('img');
                image.src = fileUrl;
                image.className = 'preview-img';
                image.alt = '保存した画像';

                image.addEventListener('error', function () {
                    showStatus('保存しましたが、画像の表示に失敗しました。', 'error');
                });

                previewContainer.appendChild(image);
                resultArea.appendChild(status);
                resultArea.appendChild(previewContainer);
            }

            function showStatus(message, type) {
                clearResultArea();

                var status = document.createElement('div');
                status.className = 'status-msg ' + type;
                status.textContent = message;
                resultArea.appendChild(status);
            }

            function clearResultArea() {
                while (resultArea.firstChild) {
                    resultArea.removeChild(resultArea.firstChild);
                }
            }

            function setButtonsDisabled(disabled) {
                cameraButton.disabled = disabled;
                libraryButton.disabled = disabled;
            }

            function resetInputs() {
                cameraInput.value = '';
                libraryInput.value = '';
            }
        }());
    </script>
</body>
</html>
