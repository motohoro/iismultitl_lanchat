<%@ Page Language="C#" AutoEventWireup="true" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Web" %>
<%@ Import Namespace="System.Runtime.InteropServices" %>

<script runat="server">
    // --- winsqlite3.dll P/Invoke 定義 ---
    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_open(string filename, out IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_close(IntPtr db);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_exec(IntPtr db, string sql, IntPtr callback, IntPtr arg, out IntPtr errmsg);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_prepare_v2(IntPtr db, string sql, int numBytes, out IntPtr stmt, IntPtr tail);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_blob(IntPtr stmt, int index, byte[] val, int numBytes, IntPtr destructor);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_bind_text(IntPtr stmt, int index, byte[] val, int numBytes, IntPtr destructor);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_step(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_finalize(IntPtr stmt);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_blob(IntPtr stmt, int col);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int sqlite3_column_bytes(IntPtr stmt, int col);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);

    [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern long sqlite3_last_insert_rowid(IntPtr db);

    private static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    private string dbPath;

    protected void Page_Load(object sender, EventArgs e)
    {
        dbPath = Server.MapPath("~/app_data.db");
        
        // DB初期化および前日以前のデータ削除を実行
        InitDatabase();

        // 1. 画像参照要求 (GET ?fileId=xxx)
        if (Request.HttpMethod == "GET" && !string.IsNullOrEmpty(Request.QueryString["fileId"]))
        {
            ServeFile(Request.QueryString["fileId"]);
            return;
        }

        // 2. ファイルアップロード要求 (POST)
        if (Request.HttpMethod == "POST" && Request.Files.Count > 0)
        {
            HandleFileUpload();
            return;
        }
    }

    private void InitDatabase()
    {
        IntPtr db;
        if (sqlite3_open(dbPath, out db) == 0)
        {
            // テーブル作成
            string createTableSql = "CREATE TABLE IF NOT EXISTS AppFiles (id INTEGER PRIMARY KEY AUTOINCREMENT, filename TEXT, content_type TEXT, file_data BLOB, created_at TEXT);";
            IntPtr errmsg;
            sqlite3_exec(db, createTableSql, IntPtr.Zero, IntPtr.Zero, out errmsg);

            // 前日までの古いデータを削除（本日の00:00:00より前のデータをDELETE）
            string todayStart = DateTime.Today.ToString("yyyy-MM-dd 00:00:00");
            string deleteOldSql = string.Format("DELETE FROM AppFiles WHERE created_at < '{0}';", todayStart);
            sqlite3_exec(db, deleteOldSql, IntPtr.Zero, IntPtr.Zero, out errmsg);

            sqlite3_close(db);
        }
    }

    private void HandleFileUpload()
    {
        Response.Clear();
        Response.ContentType = "application/json";

        try
        {
            HttpPostedFile file = Request.Files[0];
            if (file != null && file.ContentLength > 0)
            {
                byte[] fileBytes = new byte[file.ContentLength];
                file.InputStream.Read(fileBytes, 0, file.ContentLength);

                string originalName = Path.GetFileName(file.FileName);
                string contentType = file.ContentType;

                IntPtr db;
                if (sqlite3_open(dbPath, out db) == 0)
                {
                    string sql = "INSERT INTO AppFiles (filename, content_type, file_data, created_at) VALUES (?, ?, ?, ?);";
                    IntPtr stmt;

                    if (sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero) == 0)
                    {
                        byte[] nameBytes = System.Text.Encoding.UTF8.GetBytes(originalName);
                        byte[] typeBytes = System.Text.Encoding.UTF8.GetBytes(contentType);
                        byte[] timeBytes = System.Text.Encoding.UTF8.GetBytes(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"));

                        sqlite3_bind_text(stmt, 1, nameBytes, nameBytes.Length, SQLITE_TRANSIENT);
                        sqlite3_bind_text(stmt, 2, typeBytes, typeBytes.Length, SQLITE_TRANSIENT);
                        sqlite3_bind_blob(stmt, 3, fileBytes, fileBytes.Length, SQLITE_TRANSIENT);
                        sqlite3_bind_text(stmt, 4, timeBytes, timeBytes.Length, SQLITE_TRANSIENT);

                        if (sqlite3_step(stmt) == 100 || sqlite3_step(stmt) == 101) { }

                        long newId = sqlite3_last_insert_rowid(db);
                        sqlite3_finalize(stmt);
                        sqlite3_close(db);

                        string fileUrl = string.Format("{0}?fileId={1}", Request.Url.AbsolutePath, newId);

                        string jsonResponse = string.Format(
                            "{{\"success\": true, \"fileName\": \"{0}\", \"fileUrl\": \"{1}\"}}",
                            HttpUtility.JavaScriptStringEncode(originalName),
                            HttpUtility.JavaScriptStringEncode(fileUrl)
                        );
                        Response.Write(jsonResponse);
                    }
                    else
                    {
                        sqlite3_close(db);
                        Response.Write("{\"success\": false, \"message\": \"DBステートメント作成失敗\"}");
                    }
                }
            }
            else
            {
                Response.Write("{\"success\": false, \"message\": \"ファイルデータが空です。\"}");
            }
        }
        catch (Exception ex)
        {
            Response.Write(string.Format("{{\"success\": false, \"message\": \"{0}\"}}", HttpUtility.JavaScriptStringEncode(ex.Message)));
        }

        Response.End();
    }

    private void ServeFile(string idStr)
    {
        long fileId;
        if (!long.TryParse(idStr, out fileId)) return;

        IntPtr db;
        if (sqlite3_open(dbPath, out db) == 0)
        {
            string sql = "SELECT content_type, file_data FROM AppFiles WHERE id = ?;";
            IntPtr stmt;

            if (sqlite3_prepare_v2(db, sql, -1, out stmt, IntPtr.Zero) == 0)
            {
                byte[] idBytes = System.Text.Encoding.UTF8.GetBytes(fileId.ToString());
                sqlite3_bind_text(stmt, 1, idBytes, idBytes.Length, SQLITE_TRANSIENT);

                if (sqlite3_step(stmt) == 100) // SQLITE_ROW
                {
                    IntPtr typePtr = sqlite3_column_text(stmt, 0);
                    int typeBytesLen = sqlite3_column_bytes(stmt, 0);
                    byte[] typeBuffer = new byte[typeBytesLen];
                    if (typePtr != IntPtr.Zero) Marshal.Copy(typePtr, typeBuffer, 0, typeBytesLen);
                    string contentType = System.Text.Encoding.UTF8.GetString(typeBuffer);

                    IntPtr blobPtr = sqlite3_column_blob(stmt, 1);
                    int blobSize = sqlite3_column_bytes(stmt, 1);
                    byte[] fileData = new byte[blobSize];
                    if (blobPtr != IntPtr.Zero) Marshal.Copy(blobPtr, fileData, 0, blobSize);

                    sqlite3_finalize(stmt);
                    sqlite3_close(db);

                    Response.Clear();
                    Response.ContentType = string.IsNullOrEmpty(contentType) ? "image/jpeg" : contentType;
                    Response.BinaryWrite(fileData);
                    Response.End();
                    return;
                }
                sqlite3_finalize(stmt);
            }
            sqlite3_close(db);
        }
    }
</script>

<!DOCTYPE html>
<html lang="ja">
<head runat="server">
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover" />
    <title>写真撮影・SQLite保存</title>
    <style>
        * {
            box-sizing: border-box;
            -webkit-tap-highlight-color: transparent;
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

        h2 {
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
            height: 54px;
            border-radius: 12px;
            font-size: 1.05rem;
            font-weight: 600;
            border: none;
            cursor: pointer;
            transition: opacity 0.2s, transform 0.1s;
        }

        .btn-touch:active {
            opacity: 0.75;
            transform: scale(0.98);
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
        }

        .status-msg.success { background: #d1e7dd; color: #0f5132; }
        .status-msg.error { background: #f8d7da; color: #842029; }
        .status-msg.info { background: #e2e3e5; color: #41464b; }

        .preview-container {
            margin-top: 15px;
            text-align: center;
        }

        .preview-img {
            max-width: 100%;
            max-height: 380px;
            border-radius: 12px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            object-fit: contain;
        }
    </style>
</head>
<body>
    <div class="upload-card">
        <h2>写真撮影・SQLite保存</h2>
        
        <div class="action-group">
            <button type="button" class="btn-touch btn-camera" onclick="document.getElementById('cameraInput').click()">
                📷 その場で写真を撮影
            </button>
            
            <button type="button" class="btn-touch btn-library" onclick="document.getElementById('libraryInput').click()">
                🖼️ アルバムから選択
            </button>

            <input type="file" id="cameraInput" class="file-input" accept="image/*" capture="environment" />
            <input type="file" id="libraryInput" class="file-input" accept="image/*" />
        </div>

        <div id="resultArea"></div>
    </div>

    <script>
        const cameraInput = document.getElementById('cameraInput');
        const libraryInput = document.getElementById('libraryInput');
        const resultArea = document.getElementById('resultArea');

        cameraInput.addEventListener('change', (e) => handleFileSelect(e.target));
        libraryInput.addEventListener('change', (e) => handleFileSelect(e.target));

        function handleFileSelect(inputElement) {
            if (inputElement.files && inputElement.files.length > 0) {
                uploadFile(inputElement.files[0]);
            }
        }

        function uploadFile(file) {
            const formData = new FormData();
            formData.append('file', file);

            showStatus('SQLiteへ保存中...', 'info');

            fetch(window.location.href, {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    let html = `<div class="status-msg success">SQLiteデータベースへ保存完了</div>`;
                    html += `<div class="preview-container"><img src="${data.fileUrl}" class="preview-img" alt="DB保存画像" /></div>`;
                    resultArea.innerHTML = html;
                } else {
                    showStatus('エラー: ' + data.message, 'error');
                }
            })
            .catch(error => {
                console.error('Upload Error:', error);
                showStatus('送信中にエラーが発生しました。', 'error');
            })
            .finally(() => {
                cameraInput.value = '';
                libraryInput.value = '';
            });
        }

        function showStatus(message, type) {
            resultArea.innerHTML = `<div class="status-msg ${type}">${escapeHtml(message)}</div>`;
        }

        function escapeHtml(str) {
            return str.replace(/[&<>"']/g, function(m) {
                return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;' }[m];
            });
        }
    </script>
</body>
</html>
