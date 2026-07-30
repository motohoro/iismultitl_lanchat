<%@ Page Language="C#" AutoEventWireup="true" CodePage="65001" ResponseEncoding="utf-8" %>
<%@ Import Namespace="System" %>
<%@ Import Namespace="System.Globalization" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Runtime.InteropServices" %>
<%@ Import Namespace="System.Text" %>
<%@ Import Namespace="System.Web" %>

<script runat="server">
    private const int SQLITE_OK = 0;
    private const int SQLITE_ROW = 100;
    private const int SQLITE_DONE = 101;
    private const int MAX_FILE_SIZE = 15 * 1024 * 1024;
    private static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    private static readonly object InitLock = new object();
    private static readonly object CleanupLock = new object();
    private static bool databaseInitialized;
    private static DateTime lastCleanupDate = DateTime.MinValue;

    private string dbPath;
    private bool suppressPageRender;

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open16(
        [MarshalAs(UnmanagedType.LPWStr)] string filename,
        out IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(
        IntPtr db, string sql, IntPtr callback, IntPtr arg, out IntPtr errmsg);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(
        IntPtr db, string sql, int numBytes, out IntPtr stmt, IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_blob(
        IntPtr stmt, int index, byte[] value, int numBytes, IntPtr destructor);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(
        IntPtr stmt, int index, byte[] value, int numBytes, IntPtr destructor);

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

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_last_insert_rowid(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_busy_timeout(IntPtr db, int milliseconds);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_errmsg(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern void sqlite3_free(IntPtr pointer);

    protected void Page_Load(object sender, EventArgs e)
    {
        try
        {
            string dataDirectory = Server.MapPath("~/App_Data");
            Directory.CreateDirectory(dataDirectory);
            dbPath = Path.Combine(dataDirectory, "photo_share.db");

            EnsureDatabaseCreated();

            string token = Request.QueryString["token"];
            if (String.Equals(Request.HttpMethod, "GET", StringComparison.OrdinalIgnoreCase)
                && !String.IsNullOrEmpty(token))
            {
                suppressPageRender = true;
                ServeFile(token);
                Context.ApplicationInstance.CompleteRequest();
                return;
            }

            if (String.Equals(Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
            {
                suppressPageRender = true;
                HandleFileUpload();
                Context.ApplicationInstance.CompleteRequest();
                return;
            }

            CleanupOldFilesOncePerDay();
        }
        catch (Exception ex)
        {
            LogError(ex);
            if (IsPostBack || String.Equals(Request.HttpMethod, "POST", StringComparison.OrdinalIgnoreCase))
            {
                suppressPageRender = true;
                WriteJsonError(500, "サーバーの初期化に失敗しました。");
                Context.ApplicationInstance.CompleteRequest();
            }
            else
            {
                throw;
            }
        }
    }

    protected override void Render(System.Web.UI.HtmlTextWriter writer)
    {
        if (!suppressPageRender)
        {
            base.Render(writer);
        }
    }

    private int OpenDatabase(out IntPtr db)
    {
        int result = sqlite3_open16(dbPath, out db);
        if (result == SQLITE_OK)
        {
            sqlite3_busy_timeout(db, 5000);
        }
        return result;
    }

    private void EnsureDatabaseCreated()
    {
        if (databaseInitialized)
        {
            return;
        }

        lock (InitLock)
        {
            if (databaseInitialized)
            {
                return;
            }

            IntPtr db = IntPtr.Zero;
            try
            {
                int result = OpenDatabase(out db);
                if (result != SQLITE_OK)
                {
                    throw new InvalidOperationException(
                        "SQLiteデータベースを開けません。コード: " + result.ToString(CultureInfo.InvariantCulture));
                }

                ExecuteSql(db, "PRAGMA journal_mode=WAL;");
                ExecuteSql(db, "PRAGMA synchronous=NORMAL;");
                ExecuteSql(db,
                    "CREATE TABLE IF NOT EXISTS PhotoFiles (" +
                    "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                    "public_token TEXT NOT NULL UNIQUE, " +
                    "filename TEXT NOT NULL, " +
                    "content_type TEXT NOT NULL, " +
                    "file_data BLOB NOT NULL, " +
                    "created_at TEXT NOT NULL);");
                ExecuteSql(db,
                    "CREATE INDEX IF NOT EXISTS IX_PhotoFiles_CreatedAt " +
                    "ON PhotoFiles(created_at);");

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
                CheckResult(OpenDatabase(out db), db, "データベースを開く処理");
                const string sql = "DELETE FROM PhotoFiles WHERE created_at < ?;";
                CheckResult(sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero),
                    db, "削除処理の準備");

                byte[] boundary = Utf8(today.ToString("yyyy-MM-dd HH:mm:ss",
                    CultureInfo.InvariantCulture));
                CheckResult(sqlite3_bind_text(stmt, 1, boundary, boundary.Length, SQLITE_TRANSIENT),
                    db, "削除日時の設定");

                int stepResult = sqlite3_step(stmt);
                if (stepResult != SQLITE_DONE)
                {
                    throw new InvalidOperationException("古い画像の削除に失敗しました: " + GetSqliteError(db));
                }

                lastCleanupDate = today;
            }
            catch (Exception ex)
            {
                LogError(ex);
            }
            finally
            {
                if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
                if (db != IntPtr.Zero) sqlite3_close(db);
            }
        }
    }

    private void HandleFileUpload()
    {
        Response.Clear();
        Response.ContentType = "application/json; charset=utf-8";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);
        Response.Cache.SetNoStore();

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
            string contentType = DetectImageContentType(fileBytes);
            if (contentType == null)
            {
                WriteJsonError(415, "JPEGまたはPNG画像のみ送信できます。");
                return;
            }

            string originalName = SanitizeFileName(file.FileName, contentType);
            string publicToken = Guid.NewGuid().ToString("N");

            CheckResult(OpenDatabase(out db), db, "データベースを開く処理");
            const string sql =
                "INSERT INTO PhotoFiles " +
                "(public_token, filename, content_type, file_data, created_at) " +
                "VALUES (?, ?, ?, ?, ?);";
            CheckResult(sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero),
                db, "保存処理の準備");

            BindText(stmt, 1, publicToken, db);
            BindText(stmt, 2, originalName, db);
            BindText(stmt, 3, contentType, db);
            CheckResult(sqlite3_bind_blob(stmt, 4, fileBytes, fileBytes.Length, SQLITE_TRANSIENT),
                db, "画像データの設定");
            BindText(stmt, 5, DateTime.Now.ToString(
                "yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture), db);

            int stepResult = sqlite3_step(stmt);
            if (stepResult != SQLITE_DONE)
            {
                throw new InvalidOperationException("画像の保存に失敗しました: " + GetSqliteError(db));
            }

            // INSERTが成功したことの追加確認。公開URLには連番IDを使わない。
            long insertedId = sqlite3_last_insert_rowid(db);
            if (insertedId <= 0)
            {
                throw new InvalidOperationException("保存された画像IDを取得できませんでした。");
            }

            string fileUrl = ResolveUrl(Request.Path) + "?token=" +
                HttpUtility.UrlEncode(publicToken);
            Response.StatusCode = 200;
            Response.Write(
                "{\"success\":true,\"fileName\":\"" +
                HttpUtility.JavaScriptStringEncode(originalName) +
                "\",\"fileUrl\":\"" +
                HttpUtility.JavaScriptStringEncode(fileUrl) +
                "\"}");
        }
        catch (Exception ex)
        {
            LogError(ex);
            WriteJsonError(500, "画像の保存に失敗しました。");
        }
        finally
        {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
    }

    private void ServeFile(string token)
    {
        Response.Clear();
        Response.Cache.SetCacheability(HttpCacheability.NoCache);
        Response.Cache.SetNoStore();

        Guid parsedToken;
        if (token.Length != 32 || !Guid.TryParseExact(token, "N", out parsedToken))
        {
            WriteTextError(404, "画像が見つかりません。");
            return;
        }

        IntPtr db = IntPtr.Zero;
        IntPtr stmt = IntPtr.Zero;
        try
        {
            CheckResult(OpenDatabase(out db), db, "データベースを開く処理");
            const string sql =
                "SELECT content_type, file_data FROM PhotoFiles WHERE public_token = ?;";
            CheckResult(sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero),
                db, "画像取得処理の準備");
            BindText(stmt, 1, token, db);

            int stepResult = sqlite3_step(stmt);
            if (stepResult != SQLITE_ROW)
            {
                WriteTextError(404, "画像が見つかりません。");
                return;
            }

            string contentType = ReadSqliteText(stmt, 0);
            byte[] fileData = ReadSqliteBlob(stmt, 1);
            if (fileData == null || fileData.Length == 0 ||
                (contentType != "image/jpeg" && contentType != "image/png"))
            {
                WriteTextError(404, "画像が見つかりません。");
                return;
            }

            Response.StatusCode = 200;
            Response.ContentType = contentType;
            Response.AppendHeader("Content-Disposition", "inline");
            Response.AppendHeader("Content-Length",
                fileData.Length.ToString(CultureInfo.InvariantCulture));
            Response.OutputStream.Write(fileData, 0, fileData.Length);
        }
        catch (Exception ex)
        {
            LogError(ex);
            WriteTextError(500, "画像を読み込めませんでした。");
        }
        finally
        {
            if (stmt != IntPtr.Zero) sqlite3_finalize(stmt);
            if (db != IntPtr.Zero) sqlite3_close(db);
        }
    }

    private void ExecuteSql(IntPtr db, string sql)
    {
        IntPtr errorPointer = IntPtr.Zero;
        try
        {
            int result = sqlite3_exec(db, sql, IntPtr.Zero, IntPtr.Zero, out errorPointer);
            if (result != SQLITE_OK)
            {
                string message = errorPointer == IntPtr.Zero
                    ? GetSqliteError(db)
                    : ReadUtf8Pointer(errorPointer);
                throw new InvalidOperationException("SQLite処理に失敗しました: " + message);
            }
        }
        finally
        {
            if (errorPointer != IntPtr.Zero)
            {
                sqlite3_free(errorPointer);
            }
        }
    }

    private void BindText(IntPtr stmt, int index, string value, IntPtr db)
    {
        byte[] bytes = Utf8(value);
        CheckResult(sqlite3_bind_text(stmt, index, bytes, bytes.Length, SQLITE_TRANSIENT),
            db, "文字列パラメーターの設定");
    }

    private void CheckResult(int result, IntPtr db, string operation)
    {
        if (result != SQLITE_OK)
        {
            string detail = db == IntPtr.Zero ? "" : ": " + GetSqliteError(db);
            throw new InvalidOperationException(
                operation + "に失敗しました（SQLiteコード " +
                result.ToString(CultureInfo.InvariantCulture) + "）" + detail);
        }
    }

    private string GetSqliteError(IntPtr db)
    {
        if (db == IntPtr.Zero) return "詳細不明";
        IntPtr pointer = sqlite3_errmsg(db);
        return pointer == IntPtr.Zero ? "詳細不明" : ReadUtf8Pointer(pointer);
    }

    private static string ReadUtf8Pointer(IntPtr pointer)
    {
        int length = 0;
        while (Marshal.ReadByte(pointer, length) != 0)
        {
            length++;
        }
        byte[] bytes = new byte[length];
        if (length > 0) Marshal.Copy(pointer, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }

    private static byte[] Utf8(string value)
    {
        return Encoding.UTF8.GetBytes(value ?? String.Empty);
    }

    private static byte[] ReadAllBytes(Stream input, int maximumLength)
    {
        using (MemoryStream output = new MemoryStream())
        {
            byte[] buffer = new byte[81920];
            int total = 0;
            int read;
            while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
            {
                total += read;
                if (total > maximumLength)
                {
                    throw new InvalidOperationException("ファイルサイズが上限を超えています。");
                }
                output.Write(buffer, 0, read);
            }
            return output.ToArray();
        }
    }

    private static string DetectImageContentType(byte[] data)
    {
        if (data == null || data.Length < 8) return null;
        if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF)
            return "image/jpeg";
        if (data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E &&
            data[3] == 0x47 && data[4] == 0x0D && data[5] == 0x0A &&
            data[6] == 0x1A && data[7] == 0x0A)
            return "image/png";
        return null;
    }

    private static string SanitizeFileName(string suppliedName, string contentType)
    {
        string name = Path.GetFileName(suppliedName ?? String.Empty);
        foreach (char invalid in Path.GetInvalidFileNameChars())
        {
            name = name.Replace(invalid, '_');
        }
        if (String.IsNullOrWhiteSpace(name))
        {
            name = contentType == "image/png" ? "image.png" : "image.jpg";
        }
        if (name.Length > 200) name = name.Substring(0, 200);
        return name;
    }

    private static string ReadSqliteText(IntPtr stmt, int column)
    {
        IntPtr pointer = sqlite3_column_text(stmt, column);
        int length = sqlite3_column_bytes(stmt, column);
        if (pointer == IntPtr.Zero || length <= 0) return String.Empty;
        byte[] data = new byte[length];
        Marshal.Copy(pointer, data, 0, length);
        return Encoding.UTF8.GetString(data);
    }

    private static byte[] ReadSqliteBlob(IntPtr stmt, int column)
    {
        IntPtr pointer = sqlite3_column_blob(stmt, column);
        int length = sqlite3_column_bytes(stmt, column);
        if (length <= 0) return new byte[0];
        if (pointer == IntPtr.Zero) return null;
        byte[] data = new byte[length];
        Marshal.Copy(pointer, data, 0, length);
        return data;
    }

    private void WriteJsonError(int statusCode, string message)
    {
        Response.Clear();
        Response.StatusCode = statusCode;
        Response.TrySkipIisCustomErrors = true;
        Response.ContentType = "application/json; charset=utf-8";
        Response.Cache.SetCacheability(HttpCacheability.NoCache);
        Response.Cache.SetNoStore();
        Response.Write("{\"success\":false,\"message\":\"" +
            HttpUtility.JavaScriptStringEncode(message) + "\"}");
    }

    private void WriteTextError(int statusCode, string message)
    {
        Response.Clear();
        Response.StatusCode = statusCode;
        Response.TrySkipIisCustomErrors = true;
        Response.ContentType = "text/plain; charset=utf-8";
        Response.Write(message);
    }

    private void LogError(Exception exception)
    {
        try
        {
            string path = Server.MapPath("~/App_Data/photo_share_error.log");
            string entry = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) +
                " " + exception.ToString() + Environment.NewLine;
            File.AppendAllText(path, entry, Encoding.UTF8);
        }
        catch
        {
            // ログ書き込み失敗で元のエラー処理を妨げない。
        }
    }
</script>

<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover" />
    <title>写真撮影・SQLite保存</title>
    <style>
        * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", Roboto, sans-serif;
            background: #f2f2f7; color: #1c1c1e; margin: 0;
            padding: calc(20px + env(safe-area-inset-top)) 16px calc(20px + env(safe-area-inset-bottom));
            display: flex; justify-content: center; align-items: flex-start; min-height: 100vh;
        }
        .upload-card {
            background: #fff; width: 100%; max-width: 500px; padding: 24px;
            border-radius: 16px; box-shadow: 0 4px 20px rgba(0,0,0,.06);
        }
        h2 { margin: 0 0 20px; font-size: 1.25rem; text-align: center; }
        .action-group { display: flex; flex-direction: column; gap: 12px; margin-bottom: 20px; }
        .btn-touch {
            display: flex; align-items: center; justify-content: center; gap: 8px;
            width: 100%; min-height: 54px; border-radius: 12px; font-size: 1.05rem;
            font-weight: 600; border: 0; cursor: pointer;
        }
        .btn-touch:active { opacity: .75; transform: scale(.98); }
        .btn-touch:disabled { opacity: .5; cursor: default; transform: none; }
        .btn-camera { background: #007aff; color: #fff; }
        .btn-library { background: #e5e5ea; color: #007aff; }
        .file-input { display: none; }
        #resultArea { margin-top: 15px; }
        .status-msg { padding: 14px; border-radius: 10px; font-size: .95rem; text-align: center; font-weight: 500; }
        .status-msg.success { background: #d1e7dd; color: #0f5132; }
        .status-msg.error { background: #f8d7da; color: #842029; }
        .status-msg.info { background: #e2e3e5; color: #41464b; }
        .preview-container { margin-top: 15px; text-align: center; }
        .preview-img { max-width: 100%; max-height: 380px; border-radius: 12px; box-shadow: 0 2px 10px rgba(0,0,0,.1); object-fit: contain; }
    </style>
</head>
<body>
    <main class="upload-card">
        <h2>写真撮影・SQLite保存</h2>
        <div class="action-group">
            <button type="button" class="btn-touch btn-camera" id="cameraButton">📷 その場で写真を撮影</button>
            <button type="button" class="btn-touch btn-library" id="libraryButton">🖼️ アルバムから選択</button>
            <input type="file" id="cameraInput" class="file-input" accept="image/jpeg,image/png" capture="environment" />
            <input type="file" id="libraryInput" class="file-input" accept="image/jpeg,image/png" />
        </div>
        <div id="resultArea" aria-live="polite"></div>
    </main>
    <script>
        (function () {
            "use strict";
            var cameraInput = document.getElementById("cameraInput");
            var libraryInput = document.getElementById("libraryInput");
            var cameraButton = document.getElementById("cameraButton");
            var libraryButton = document.getElementById("libraryButton");
            var resultArea = document.getElementById("resultArea");
            var uploading = false;

            cameraButton.addEventListener("click", function () { cameraInput.click(); });
            libraryButton.addEventListener("click", function () { libraryInput.click(); });
            cameraInput.addEventListener("change", function () { selectFile(cameraInput); });
            libraryInput.addEventListener("change", function () { selectFile(libraryInput); });

            function selectFile(input) {
                if (input.files && input.files.length > 0) uploadFile(input.files[0]);
            }

            function setDisabled(disabled) {
                cameraButton.disabled = disabled;
                libraryButton.disabled = disabled;
            }

            function showStatus(message, type) {
                resultArea.textContent = "";
                var status = document.createElement("div");
                status.className = "status-msg " + type;
                status.textContent = message;
                resultArea.appendChild(status);
            }

            function uploadFile(file) {
                if (uploading || !file) return;
                if (file.size > 15 * 1024 * 1024) {
                    showStatus("画像は15MB以下にしてください。", "error");
                    return;
                }

                uploading = true;
                setDisabled(true);
                showStatus("SQLiteへ保存中...", "info");

                var formData = new FormData();
                formData.append("file", file, file.name);
                var request = new XMLHttpRequest();
                request.open("POST", window.location.pathname, true);
                request.setRequestHeader("Accept", "application/json");
                request.onreadystatechange = function () {
                    if (request.readyState !== 4) return;
                    try {
                        var data = JSON.parse(request.responseText);
                        if (request.status < 200 || request.status >= 300 || !data.success) {
                            throw new Error(data.message || "保存に失敗しました。");
                        }
                        resultArea.textContent = "";
                        var status = document.createElement("div");
                        status.className = "status-msg success";
                        status.textContent = "SQLiteデータベースへ保存完了";
                        var preview = document.createElement("div");
                        preview.className = "preview-container";
                        var image = document.createElement("img");
                        image.src = data.fileUrl;
                        image.className = "preview-img";
                        image.alt = "DB保存画像";
                        preview.appendChild(image);
                        resultArea.appendChild(status);
                        resultArea.appendChild(preview);
                    } catch (error) {
                        showStatus(error.message || "送信中にエラーが発生しました。", "error");
                    } finally {
                        uploading = false;
                        setDisabled(false);
                        cameraInput.value = "";
                        libraryInput.value = "";
                    }
                };
                request.onerror = function () {
                    showStatus("サーバーへ接続できませんでした。", "error");
                    uploading = false;
                    setDisabled(false);
                };
                request.send(formData);
            }
        }());
    </script>
</body>
</html>
