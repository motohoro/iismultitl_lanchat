<%@ Page Language="C#" AutoEventWireup="true" %>
<%@ Import Namespace="System" %>
<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.Linq" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>

<script runat="server">
    public class ReplyModel
    {
        public string Id { get; set; }
        public string Text { get; set; }
        public string ImageBase64 { get; set; }
        public string ClientId { get; set; }
        public DateTime CreatedAt { get; set; }
    }

    public class ThreadModel
    {
        public string Id { get; set; }
        public string Title { get; set; }     // 作成日時
        public string Text { get; set; }
        public string ImageBase64 { get; set; }
        public string ClientId { get; set; }  // 送信元識別ID
        public DateTime CreatedAt { get; set; }
        public List<ReplyModel> Replies { get; set; }

        public ThreadModel()
        {
            Replies = new List<ReplyModel>();
        }
    }

    private static readonly List<ThreadModel> _threads = new List<ThreadModel>();
    private static readonly object _lock = new object();

    protected void Page_Load(object sender, EventArgs e)
    {
        string action = Request.QueryString["action"];

        if (!string.IsNullOrEmpty(action))
        {
            Response.ContentType = "application/json";
            var serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = int.MaxValue;

            // 【新規スレッド投稿】
            if (action == "post")
            {
                string text = Request.Form["text"];
                string imageBase64 = Request.Form["imageBase64"];
                string clientId = Request.Form["clientId"];

                DateTime now = DateTime.Now;
                var thread = new ThreadModel
                {
                    Id = Guid.NewGuid().ToString(),
                    Title = now.ToString("yyyy/MM/dd HH:mm:ss"),
                    Text = text,
                    ImageBase64 = imageBase64,
                    ClientId = clientId,
                    CreatedAt = now
                };

                lock (_lock)
                {
                    _threads.Add(thread);
                }

                Response.Write(serializer.Serialize(new { success = true }));
                Response.End();
            }
            // 【レス（返信）投稿】
            else if (action == "reply")
            {
                string threadId = Request.Form["threadId"];
                string text = Request.Form["text"];
                string imageBase64 = Request.Form["imageBase64"];
                string clientId = Request.Form["clientId"];

                lock (_lock)
                {
                    var target = _threads.FirstOrDefault(t => t.Id == threadId);
                    if (target != null)
                    {
                        target.Replies.Add(new ReplyModel
                        {
                            Id = Guid.NewGuid().ToString(),
                            Text = text,
                            ImageBase64 = imageBase64,
                            ClientId = clientId,
                            CreatedAt = DateTime.Now
                        });
                    }
                }

                Response.Write(serializer.Serialize(new { success = true }));
                Response.End();
            }
            // 【一覧取得（降順）】
            else if (action == "get")
            {
                List<ThreadModel> result;
                lock (_lock)
                {
                    result = _threads.OrderByDescending(t => t.CreatedAt).ToList();
                }

                Response.Write(serializer.Serialize(result));
                Response.End();
            }
        }
    }
</script>

<!DOCTYPE html>
<html lang="ja">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>SMS風 掲示板</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            margin: 0;
            padding: 12px;
            background-color: #f2f2f7;
            color: #000;
        }

        .control-panel {
            background: #fff;
            border-radius: 12px;
            padding: 10px 15px;
            margin-bottom: 12px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            font-size: 14px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.05);
        }

        /* 投稿カードエリア */
        .post-card {
            background: #fff;
            border-radius: 16px;
            padding: 16px 12px;
            margin-bottom: 20px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.08);
            text-align: center;
        }

        /* ① メイン：カメラ起動ボタン（超大型） */
        .camera-btn {
            display: flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            width: 100%;
            padding: 18px 0;
            background: #007aff;
            color: #fff;
            font-weight: bold;
            font-size: 18px;
            border-radius: 14px;
            box-sizing: border-box;
            cursor: pointer;
            box-shadow: 0 4px 10px rgba(0, 122, 255, 0.3);
            border: none;
        }
        .camera-btn:active { background: #0056b3; transform: scale(0.98); }

        /* ② サブ：ライブラリ選択ボタン（誤操作防止のため極小・目立たなく配置） */
        .library-btn-wrapper {
            margin-top: 10px;
            text-align: right;
        }
        .library-btn {
            display: inline-block;
            font-size: 11px;
            color: #8e8e93;
            background: #f2f2f7;
            padding: 4px 8px;
            border-radius: 6px;
            cursor: pointer;
            text-decoration: underline;
        }

        /* 非表示のfile input */
        input[type="file"] { display: none; }

        /* 送信中オーバーレイ表示 */
        .sending-overlay {
            display: none;
            margin-top: 10px;
            font-size: 14px;
            color: #007aff;
            font-weight: bold;
        }

        .chat-container {
            display: flex;
            flex-direction: column;
            gap: 16px;
        }

        /* SMSバブル */
        .chat-bubble {
            max-width: 88%;
            padding: 12px;
            border-radius: 18px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
            position: relative;
            word-wrap: break-word;
        }

        .chat-bubble.me {
            align-self: flex-end;
            background-color: #007aff;
            color: #fff;
            border-bottom-right-radius: 4px;
        }

        .chat-bubble.other {
            align-self: flex-start;
            background-color: #e9e9eb;
            color: #000;
            border-bottom-left-radius: 4px;
        }

        .bubble-time {
            font-size: 0.72em;
            margin-bottom: 6px;
            opacity: 0.8;
        }
        .chat-bubble.me .bubble-time { text-align: right; color: #e0f0ff; }
        .chat-bubble.other .bubble-time { text-align: left; color: #666; }

        .bubble-img {
            max-width: 100%;
            height: auto;
            border-radius: 12px;
            display: block;
            margin-top: 4px;
            cursor: pointer;
            transition: opacity 0.2s;
        }
        .bubble-img:active { opacity: 0.7; }

        .tap-hint {
            font-size: 11px;
            margin-top: 4px;
            opacity: 0.75;
            text-align: right;
        }

        .bubble-text {
            font-size: 15px;
            line-height: 1.35;
            margin-top: 6px;
            white-space: pre-wrap;
            word-break: break-all;
        }

        /* レス入力領域 */
        .reply-form {
            display: none;
            margin-top: 10px;
            padding: 10px;
            background: rgba(255, 255, 255, 0.25);
            backdrop-filter: blur(5px);
            border-radius: 12px;
            border: 1px dashed rgba(0,0,0,0.15);
        }
        .chat-bubble.me .reply-form { background: rgba(0,0,0,0.15); color: #fff; }

        .reply-form input[type="text"] {
            margin-bottom: 6px;
            height: 36px;
            font-size: 14px;
            width: 100%;
            border-radius: 6px;
            border: 1px solid #ccc;
            padding: 0 8px;
            box-sizing: border-box;
        }
        .reply-form-btn {
            padding: 8px;
            font-size: 14px;
            background: #34c759;
            color: white;
            border: none;
            border-radius: 8px;
            width: 100%;
            font-weight: bold;
        }
        .reply-file-label {
            display: inline-block;
            font-size: 12px;
            padding: 6px 10px;
            background: rgba(255,255,255,0.8);
            color: #333;
            border-radius: 6px;
            margin-bottom: 6px;
            cursor: pointer;
        }

        .replies-list {
            margin-top: 10px;
            border-top: 1px solid rgba(0,0,0,0.1);
            padding-top: 8px;
            display: flex;
            flex-direction: column;
            gap: 8px;
        }
        .chat-bubble.me .replies-list { border-top-color: rgba(255,255,255,0.2); }

        .reply-item {
            background: rgba(255,255,255,0.85);
            padding: 8px 10px;
            border-radius: 10px;
            font-size: 14px;
            color: #000;
            transition: background-color 1s ease;
        }
        .chat-bubble.me .reply-item { background: rgba(255,255,255,0.92); }
        .reply-item img { max-width: 100%; border-radius: 8px; margin-top: 4px; }
        .reply-time { font-size: 10px; color: #666; margin-bottom: 2px; }

        /* 新着ハイライト */
        @keyframes highlightAnimation {
            0% { background-color: #ffe066; transform: scale(1.02); }
            100% { background-color: rgba(255,255,255,0.85); transform: scale(1); }
        }
        .reply-item.new-arrival { animation: highlightAnimation 2s ease-out; }
    </style>
</head>
<body>

    <div class="control-panel">
        <strong id="audio-status">🔊 通知音: 画面タップで有効化</strong>
        <label>
            <input type="checkbox" id="mute-toggle"> 消音
        </label>
    </div>

    <!-- メイン投稿フォーム（撮影/選択後 即時送信） -->
    <div class="post-card">
        <!-- ① メイン：直接カメラが起動するボタン（capture="environment"） -->
        <label for="camera-input" class="camera-btn">
            📷 カメラで撮影して新規投稿
        </label>
        <input type="file" id="camera-input" accept="image/*" capture="environment">

        <!-- ② サブ：アルバムから選ぶ控えめなボタン -->
        <div class="library-btn-wrapper">
            <label for="library-input" class="library-btn">
                📁 撮影済みの写真を選択
            </label>
            <input type="file" id="library-input" accept="image/*">
        </div>

        <div id="sending-overlay" class="sending-overlay">
            ⏳ 送信中...
        </div>
    </div>

    <!-- SMSタイムライン -->
    <div id="chat-container" class="chat-container"></div>

    <!-- 通知音 -->
    <audio id="notify-sound" preload="auto">
        <source src="notification.mp3" type="audio/mpeg">
    </audio>

    <script>
        const myClientId = 'client_' + Math.random().toString(36).substring(2) + Date.now().toString(36);
        const knownThreadIds = new Set();
        const knownReplyIds = new Set();
        let isFirstLoad = true;
        let audioUnlocked = false;

        const sound = document.getElementById('notify-sound');
        const audioStatus = document.getElementById('audio-status');
        const cameraInput = document.getElementById('camera-input');
        const libraryInput = document.getElementById('library-input');
        const sendingOverlay = document.getElementById('sending-overlay');

        // iOS Safari 音声アンロック
        const unlockAudio = () => {
            if (!audioUnlocked) {
                sound.play().then(() => {
                    sound.pause();
                    sound.currentTime = 0;
                    audioUnlocked = true;
                    audioStatus.innerText = '🔊 通知音: 有効';
                }).catch(() => {});
            }
        };
        document.addEventListener('touchstart', unlockAudio, { once: true });
        document.addEventListener('click', unlockAudio, { once: true });

        // カメラ撮影完了 または ライブラリ選択完了時に自動で即時送信
        cameraInput.addEventListener('change', (e) => handleAutoPost(e.target));
        libraryInput.addEventListener('change', (e) => handleAutoPost(e.target));

        async function handleAutoPost(inputElem) {
            if (!inputElem.files || inputElem.files.length === 0) return;

            const file = inputElem.files[0];
            sendingOverlay.style.display = 'block';

            try {
                // 画像リサイズ（1024pxに縮小）
                const imageBase64 = await resizeImage(file, 1024);

                const formData = new FormData();
                formData.append('text', ''); // 文字は不要のため空文字
                formData.append('imageBase64', imageBase64);
                formData.append('clientId', myClientId);

                // 即送信
                await fetch('?action=post', { method: 'POST', body: formData });

                // 一覧を即更新
                await fetchThreads();
            } catch (err) {
                alert('送信に失敗しました。');
                console.error(err);
            } finally {
                inputElem.value = ''; // ファイル選択リセット
                sendingOverlay.style.display = 'none';
            }
        }

        // スレッド＆レスの定期取得
        async function fetchThreads() {
            try {
                const response = await fetch('?action=get');
                if (!response.ok) return;
                
                const threads = await response.json();
                let hasSoundTriggered = false;

                threads.forEach(thread => {
                    if (!knownThreadIds.has(thread.Id)) {
                        knownThreadIds.add(thread.Id);
                        renderThread(thread, !isFirstLoad);

                        if (!isFirstLoad && thread.ClientId !== myClientId) {
                            hasSoundTriggered = true;
                        }
                    }

                    if (thread.Replies && thread.Replies.length > 0) {
                        thread.Replies.forEach(reply => {
                            if (!knownReplyIds.has(reply.Id)) {
                                knownReplyIds.add(reply.Id);
                                appendReplyUI(thread.Id, reply, !isFirstLoad);

                                if (!isFirstLoad && reply.ClientId !== myClientId) {
                                    hasSoundTriggered = true;
                                }
                            }
                        });
                    }
                });

                const isMuted = document.getElementById('mute-toggle').checked;
                if (hasSoundTriggered && !isMuted && audioUnlocked) {
                    sound.currentTime = 0;
                    sound.play().catch(e => console.log('Audio error:', e));
                }

                isFirstLoad = false;
            } catch (err) {
                console.error('Fetch error:', err);
            }
        }

        function toggleReplyForm(threadId) {
            const form = document.getElementById(`reply-form-${threadId}`);
            if (form) {
                form.style.display = (form.style.display === 'block') ? 'none' : 'block';
            }
        }

        // レス送信処理
        async function sendReply(threadId) {
            const textInput = document.getElementById(`reply-text-${threadId}`);
            const fileInputElem = document.getElementById(`reply-file-${threadId}`);

            if (!textInput.value.trim() && fileInputElem.files.length === 0) {
                alert('文字または画像を入力してください。');
                return;
            }

            let imageBase64 = '';
            if (fileInputElem.files.length > 0) {
                imageBase64 = await resizeImage(fileInputElem.files[0], 1024);
            }

            const formData = new FormData();
            formData.append('threadId', threadId);
            formData.append('text', textInput.value);
            formData.append('imageBase64', imageBase64);
            formData.append('clientId', myClientId);

            await fetch('?action=reply', { method: 'POST', body: formData });

            textInput.value = '';
            fileInputElem.value = '';
            document.getElementById(`reply-file-label-${threadId}`).innerText = '📷 返信画像を追加（任意）';
            toggleReplyForm(threadId);

            fetchThreads();
        }

        // スレッド画面描画
        function renderThread(thread, isNew) {
            const container = document.getElementById('chat-container');
            const bubble = document.createElement('div');
            
            const isMe = (thread.ClientId === myClientId);
            bubble.className = `chat-bubble ${isMe ? 'me' : 'other'}`;
            bubble.id = `thread-bubble-${thread.Id}`;
            
            let imgHtml = thread.ImageBase64 
                ? `<img class="bubble-img" src="${thread.ImageBase64}" onclick="toggleReplyForm('${thread.Id}')" />
                   <div class="tap-hint">👆 画像タップで返信</div>` 
                : '';

            let replyFormHtml = `
                <div class="reply-form" id="reply-form-${thread.Id}">
                    <label class="reply-file-label" id="reply-file-label-${thread.Id}" for="reply-file-${thread.Id}">📷 返信画像を追加（任意）</label>
                    <input type="file" id="reply-file-${thread.Id}" accept="image/*" onchange="updateReplyFileLabel('${thread.Id}')">
                    <input type="text" id="reply-text-${thread.Id}" placeholder="返信メッセージ（1行）">
                    <button class="reply-form-btn" onclick="sendReply('${thread.Id}')">返信を送信</button>
                </div>
                <div class="replies-list" id="replies-list-${thread.Id}" style="display:none;"></div>
            `;

            bubble.innerHTML = `
                <div class="bubble-time">📅 ${escapeHtml(thread.Title)}</div>
                ${imgHtml}
                ${replyFormHtml}
            `;

            if (isNew) {
                container.insertBefore(bubble, container.firstChild);
            } else {
                container.appendChild(bubble);
            }
        }

        function appendReplyUI(threadId, reply, isNew) {
            const repliesContainer = document.getElementById(`replies-list-${threadId}`);
            if (!repliesContainer) return;

            repliesContainer.style.display = 'flex';

            const item = document.createElement('div');
            item.className = 'reply-item' + (isNew ? ' new-arrival' : '');

            let imgHtml = reply.ImageBase64 ? `<img src="${reply.ImageBase64}" />` : '';
            let textHtml = reply.Text ? `<div>${escapeHtml(reply.Text)}</div>` : '';

            item.innerHTML = `
                <div class="reply-time">${new Date(parseInt(reply.CreatedAt.replace(/[^0-9]/g, ''))).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'})}</div>
                ${imgHtml}
                ${textHtml}
            `;

            repliesContainer.appendChild(item);
        }

        function updateReplyFileLabel(threadId) {
            const input = document.getElementById(`reply-file-${threadId}`);
            const label = document.getElementById(`reply-file-label-${threadId}`);
            if (input.files.length > 0) {
                label.innerText = '📷 ' + input.files[0].name;
            }
        }

        function resizeImage(file, maxWidth) {
            return new Promise((resolve) => {
                const reader = new FileReader();
                reader.onload = (e) => {
                    const img = new Image();
                    img.onload = () => {
                        const canvas = document.createElement('canvas');
                        let width = img.width;
                        let height = img.height;

                        if (width > maxWidth) {
                            height = Math.round((height * maxWidth) / width);
                            width = maxWidth;
                        }

                        canvas.width = width;
                        canvas.height = height;
                        const ctx = canvas.getContext('2d');
                        ctx.drawImage(img, 0, 0, width, height);
                        resolve(canvas.toDataURL('image/jpeg', 0.8));
                    };
                    img.src = e.target.result;
                };
                reader.readAsDataURL(file);
            });
        }

        function escapeHtml(str) {
            return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
        }

        fetchThreads();
        setInterval(fetchThreads, 3000);
    </script>
</body>
</html>
