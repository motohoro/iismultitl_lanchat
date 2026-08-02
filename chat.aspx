<%@ Page Language="C#" AutoEventWireup="true" %>
<%@ Import Namespace="System" %>
<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.Linq" %>
<%@ Import Namespace="System.IO" %>
<%@ Import Namespace="System.Text" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>

<script runat="server">
public class ReplyModel {
    public string Id { get; set; }
    public string Text { get; set; }
    public string ImageBase64 { get; set; }
    public string ClientId { get; set; }
    public DateTime CreatedAt { get; set; }
}

public class ThreadModel {
    public string Id { get; set; }
    public string Title { get; set; }
    public string Text { get; set; }
    public string ImageBase64 { get; set; }
    public string ClientId { get; set; }
    public DateTime CreatedAt { get; set; }
    public List<ReplyModel> Replies { get; set; }
    public ThreadModel() { Replies = new List<ReplyModel>(); }
}

private static readonly object _fileLock = new object();

private string GetFilePath() {
    return Server.MapPath("~/App_Data/chat.json");
}

private List<ThreadModel> LoadAndCleanupData() {
    lock (_fileLock) {
        string filePath = GetFilePath();
        if (!File.Exists(filePath)) return new List<ThreadModel>();

        try {
            string json = File.ReadAllText(filePath, Encoding.UTF8);
            var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
            var threads = serializer.Deserialize<List<ThreadModel>>(json) ?? new List<ThreadModel>();

            DateTime today = DateTime.Today;

            // 今日作成されたスレッドのみ残す（昨日以前のものは自動削除）
            var filteredThreads = threads.Where(t => t.CreatedAt.Date == today).ToList();

            foreach (var t in filteredThreads) {
                if (t.Replies != null) {
                    t.Replies = t.Replies.Where(r => r.CreatedAt.Date == today).ToList();
                }
            }

            if (filteredThreads.Count != threads.Count) {
                SaveDataInternal(filteredThreads);
            }

            return filteredThreads;
        }
        catch {
            return new List<ThreadModel>();
        }
    }
}

private void SaveData(List<ThreadModel> threads) {
    lock (_fileLock) {
        SaveDataInternal(threads);
    }
}

private void SaveDataInternal(List<ThreadModel> threads) {
    string filePath = GetFilePath();
    string dir = Path.GetDirectoryName(filePath);
    if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);

    var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
    string json = serializer.Serialize(threads);
    File.WriteAllText(filePath, json, Encoding.UTF8);
}

protected void Page_Load(object sender, EventArgs e) {
    string action = Request.QueryString["action"];
    if (string.IsNullOrEmpty(action)) return;

    Response.ContentType = "application/json";
    var serializer = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };

    if (action == "post") {
        var threads = LoadAndCleanupData();
        DateTime now = DateTime.Now;
        
        threads.Add(new ThreadModel {
            Id = Guid.NewGuid().ToString(),
            Title = now.ToString("yyyy/MM/dd HH:mm:ss"),
            Text = Request.Form["text"] ?? "",
            ImageBase64 = Request.Form["imageBase64"] ?? "",
            ClientId = Request.Form["clientId"] ?? "",
            CreatedAt = now
        });

        SaveData(threads);
        Response.Write(serializer.Serialize(new { success = true }));
        Response.End();
    }
    else if (action == "reply") {
        var threads = LoadAndCleanupData();
        string threadId = Request.Form["threadId"];
        var target = threads.FirstOrDefault(t => t.Id == threadId);

        if (target != null) {
            target.Replies.Add(new ReplyModel {
                Id = Guid.NewGuid().ToString(),
                Text = Request.Form["text"] ?? "",
                ImageBase64 = Request.Form["imageBase64"] ?? "",
                ClientId = Request.Form["clientId"] ?? "",
                CreatedAt = DateTime.Now
            });
            SaveData(threads);
        }

        Response.Write(serializer.Serialize(new { success = true }));
        Response.End();
    }
    else if (action == "get") {
        var threads = LoadAndCleanupData()
            .OrderByDescending(t => t.CreatedAt)
            .ToList();

        Response.Write(serializer.Serialize(threads));
        Response.End();
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
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; margin: 0; padding: 12px; background-color: #f2f2f7; color: #000; overflow-x: hidden; }
.control-panel { background: #fff; border-radius: 12px; padding: 10px 15px; margin-bottom: 12px; display: flex; justify-content: space-between; align-items: center; font-size: 14px; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
.post-card { background: #fff; border-radius: 16px; padding: 16px 12px; margin-bottom: 20px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); text-align: center; }
.camera-btn { display: flex; align-items: center; justify-content: center; gap: 8px; width: 100%; padding: 18px 0; background: #007aff; color: #fff; font-weight: bold; font-size: 18px; border-radius: 14px; box-sizing: border-box; cursor: pointer; box-shadow: 0 4px 10px rgba(0, 122, 255, 0.3); border: none; }
.camera-btn:active { background: #0056b3; transform: scale(0.98); }
.library-btn-wrapper { margin-top: 10px; text-align: right; }
.library-btn { display: inline-block; font-size: 11px; color: #8e8e93; background: #f2f2f7; padding: 4px 8px; border-radius: 6px; cursor: pointer; text-decoration: underline; }
input[type="file"] { display: none; }
.sending-overlay { display: none; margin-top: 10px; font-size: 14px; color: #007aff; font-weight: bold; }
.chat-container { display: flex; flex-direction: column; gap: 16px; }

/* SMSバブル */
.chat-bubble {
    max-width: 88%; padding: 12px; border-radius: 18px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); position: relative; word-wrap: break-word;
    touch-action: pan-y;
    transition: transform 0.2s ease-out, opacity 0.2s ease-out;
    will-change: transform;
}
.chat-bubble.archived { display: none !important; }
.chat-bubble.me { align-self: flex-end; background-color: #007aff; color: #fff; border-bottom-right-radius: 4px; }
.chat-bubble.other { align-self: flex-start; background-color: #e9e9eb; color: #000; border-bottom-left-radius: 4px; }
.bubble-time { font-size: 0.72em; margin-bottom: 6px; opacity: 0.8; }
.chat-bubble.me .bubble-time { text-align: right; color: #e0f0ff; }
.chat-bubble.other .bubble-time { text-align: left; color: #666; }
.bubble-img { max-width: 100%; height: auto; border-radius: 12px; display: block; margin-top: 4px; cursor: pointer; }
.bubble-text { font-size: 15px; line-height: 1.35; margin-top: 6px; white-space: pre-wrap; word-break: break-all; }
.bubble-action-bar { display: flex; justify-content: space-between; align-items: center; margin-top: 8px; font-size: 11px; opacity: 0.85; }
.reply-trigger-btn { background: rgba(0,0,0,0.1); border: none; padding: 4px 8px; border-radius: 6px; color: inherit; cursor: pointer; font-size: 11px; }

.reply-form { display: none; margin-top: 10px; padding: 10px; background: rgba(255, 255, 255, 0.25); backdrop-filter: blur(5px); border-radius: 12px; border: 1px dashed rgba(0,0,0,0.15); }
.chat-bubble.me .reply-form { background: rgba(0,0,0,0.15); color: #fff; }
.reply-form input[type="text"] { margin-bottom: 6px; height: 36px; font-size: 14px; width: 100%; border-radius: 6px; border: 1px solid #ccc; padding: 0 8px; box-sizing: border-box; }
.reply-form-btn { padding: 8px; font-size: 14px; background: #34c759; color: white; border: none; border-radius: 8px; width: 100%; font-weight: bold; }
.reply-file-label { display: inline-block; font-size: 12px; padding: 6px 10px; background: rgba(255,255,255,0.8); color: #333; border-radius: 6px; margin-bottom: 6px; cursor: pointer; }
.replies-list { margin-top: 10px; border-top: 1px solid rgba(0,0,0,0.1); padding-top: 8px; display: flex; flex-direction: column; gap: 8px; }
.chat-bubble.me .replies-list { border-top-color: rgba(255,255,255,0.2); }
.reply-item { background: rgba(255,255,255,0.85); padding: 8px 10px; border-radius: 10px; font-size: 14px; color: #000; }
.reply-item img { max-width: 100%; border-radius: 8px; margin-top: 4px; cursor: pointer; }
.reply-time { font-size: 10px; color: #666; margin-bottom: 2px; }

/* 画像拡大モーダル */
.modal-overlay {
    display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%;
    background: rgba(0, 0, 0, 0.9); z-index: 9999;
    justify-content: center; align-items: center;
}
.modal-overlay img { max-width: 95%; max-height: 90vh; border-radius: 8px; object-fit: contain; }
.modal-close-hint { position: absolute; top: 20px; color: #fff; font-size: 14px; background: rgba(0,0,0,0.5); padding: 6px 12px; border-radius: 20px; }
</style>
</head>
<body>

<div class="control-panel">
    <strong id="audio-status">🔊 通知音: 画面タップで有効化</strong>
    <label><input type="checkbox" id="mute-toggle"> 消音</label>
</div>

<div class="post-card">
    <label for="camera-input" class="camera-btn">📷 カメラで撮影して新規投稿</label>
    <input type="file" id="camera-input" accept="image/*" capture="environment">
    <div class="library-btn-wrapper">
        <label for="library-input" class="library-btn">📁 撮影済みの写真を選択</label>
        <input type="file" id="library-input" accept="image/*">
    </div>
    <div id="sending-overlay" class="sending-overlay">⏳ 送信中...</div>
</div>

<div id="chat-container" class="chat-container"></div>

<div id="image-modal" class="modal-overlay" onclick="closeImageModal()">
    <div class="modal-close-hint">タップで閉じる</div>
    <img id="modal-img" src="" alt="拡大画像">
</div>

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

const unlockAudio = () => {
    if (!audioUnlocked) {
        sound.play().then(() => { sound.pause(); sound.currentTime = 0; audioUnlocked = true; audioStatus.innerText = '🔊 通知音: 有効'; }).catch(() => {});
    }
};
document.addEventListener('touchstart', unlockAudio, { once: true });
document.addEventListener('click', unlockAudio, { once: true });

cameraInput.addEventListener('change', (e) => handleAutoPost(e.target));
libraryInput.addEventListener('change', (e) => handleAutoPost(e.target));

async function handleAutoPost(inputElem) {
    if (!inputElem.files || inputElem.files.length === 0) return;
    const file = inputElem.files[0];
    sendingOverlay.style.display = 'block';
    try {
        const imageBase64 = await resizeImage(file, 1024);
        const formData = new FormData();
        formData.append('text', '');
        formData.append('imageBase64', imageBase64);
        formData.append('clientId', myClientId);
        await fetch('?action=post', { method: 'POST', body: formData });
        await fetchThreads();
    } catch (err) { alert('送信に失敗しました。'); console.error(err); }
    finally { inputElem.value = ''; sendingOverlay.style.display = 'none'; }
}

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
                if (!isFirstLoad && thread.ClientId !== myClientId) hasSoundTriggered = true;
            }
            if (thread.Replies && thread.Replies.length > 0) {
                thread.Replies.forEach(reply => {
                    if (!knownReplyIds.has(reply.Id)) {
                        knownReplyIds.add(reply.Id);
                        appendReplyUI(thread.Id, reply, !isFirstLoad);
                        if (!isFirstLoad && reply.ClientId !== myClientId) hasSoundTriggered = true;
                    }
                });
            }
        });
        const isMuted = document.getElementById('mute-toggle').checked;
        if (hasSoundTriggered && !isMuted && audioUnlocked) {
            sound.currentTime = 0; sound.play().catch(e => console.log('Audio error:', e));
        }
        isFirstLoad = false;
    } catch (err) { console.error('Fetch error:', err); }
}

function toggleReplyForm(threadId) {
    const form = document.getElementById(`reply-form-${threadId}`);
    if (form) form.style.display = (form.style.display === 'block') ? 'none' : 'block';
}

async function sendReply(threadId) {
    const textInput = document.getElementById(`reply-text-${threadId}`);
    const fileInputElem = document.getElementById(`reply-file-${threadId}`);
    if (!textInput.value.trim() && fileInputElem.files.length === 0) { alert('文字または画像を入力してください。'); return; }
    let imageBase64 = '';
    if (fileInputElem.files.length > 0) imageBase64 = await resizeImage(fileInputElem.files[0], 1024);
    const formData = new FormData();
    formData.append('threadId', threadId);
    formData.append('text', textInput.value);
    formData.append('imageBase64', imageBase64);
    formData.append('clientId', myClientId);
    await fetch('?action=reply', { method: 'POST', body: formData });
    textInput.value = ''; fileInputElem.value = '';
    document.getElementById(`reply-file-label-${threadId}`).innerText = '📷 返信画像を追加（任意）';
    toggleReplyForm(threadId);
    fetchThreads();
}

function openImageModal(src) {
    const modal = document.getElementById('image-modal');
    const modalImg = document.getElementById('modal-img');
    modalImg.src = src;
    modal.style.display = 'flex';
}
function closeImageModal() {
    document.getElementById('image-modal').style.display = 'none';
}

function attachSwipeToArchive(element, threadId) {
    if (localStorage.getItem('archive_' + threadId) === 'true') {
        element.classList.add('archived');
        return;
    }

    let startX = 0;
    let currentX = 0;
    let isSwiping = false;

    element.addEventListener('touchstart', (e) => {
        startX = e.touches[0].clientX;
        isSwiping = true;
        element.style.transition = 'none';
    }, { passive: true });

    element.addEventListener('touchmove', (e) => {
        if (!isSwiping) return;
        currentX = e.touches[0].clientX - startX;
        element.style.transform = `translateX(${currentX}px)`;
    }, { passive: true });

    element.addEventListener('touchend', () => {
        if (!isSwiping) return;
        isSwiping = false;
        element.style.transition = 'transform 0.2s ease-out, opacity 0.2s ease-out';

        if (Math.abs(currentX) > 120) {
            const direction = currentX > 0 ? 1 : -1;
            element.style.transform = `translateX(${direction * 100}vw)`;
            element.style.opacity = '0';
            
            setTimeout(() => {
                element.classList.add('archived');
                localStorage.setItem('archive_' + threadId, 'true');
            }, 200);
        } else {
            element.style.transform = 'translateX(0)';
        }
        currentX = 0;
    });
}

function renderThread(thread, isNew) {
    const container = document.getElementById('chat-container');
    const bubble = document.createElement('div');
    const isMe = (thread.ClientId === myClientId);
    bubble.className = `chat-bubble ${isMe ? 'me' : 'other'}`;
    bubble.id = `thread-bubble-${thread.Id}`;

    let imgHtml = thread.ImageBase64 ? `<img class="bubble-img" src="${thread.ImageBase64}" onclick="openImageModal('${thread.ImageBase64}')" />` : '';
    let textHtml = thread.Text ? `<div class="bubble-text">${escapeHtml(thread.Text)}</div>` : '';
    
    let actionBarHtml = `
        <div class="bubble-action-bar">
            <span>👈👉 スワイプで非表示</span>
            <button class="reply-trigger-btn" onclick="toggleReplyForm('${thread.Id}')">💬 返信</button>
        </div>
    `;

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
        ${textHtml}
        ${actionBarHtml}
        ${replyFormHtml}
    `;

    if (isNew) { container.insertBefore(bubble, container.firstChild); }
    else { container.appendChild(bubble); }

    attachSwipeToArchive(bubble, thread.Id);
}

function appendReplyUI(threadId, reply, isNew) {
    const repliesContainer = document.getElementById(`replies-list-${threadId}`);
    if (!repliesContainer) return;
    repliesContainer.style.display = 'flex';
    const item = document.createElement('div');
    item.className = 'reply-item';
    let imgHtml = reply.ImageBase64 ? `<img src="${reply.ImageBase64}" onclick="openImageModal('${reply.ImageBase64}')" />` : '';
    let textHtml = reply.Text ? `<div>${escapeHtml(reply.Text)}</div>` : '';
    item.innerHTML = `
        <div class="reply-time">${new Date(parseInt(reply.CreatedAt.replace(/[^0-9]/g, ''))).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'})}</div>
        ${imgHtml} ${textHtml}
    `;
    repliesContainer.appendChild(item);
}

function updateReplyFileLabel(threadId) {
    const input = document.getElementById(`reply-file-${threadId}`);
    const label = document.getElementById(`reply-file-label-${threadId}`);
    if (input.files.length > 0) label.innerText = '📷 ' + input.files[0].name;
}

function resizeImage(file, maxWidth) {
    return new Promise((resolve) => {
        const reader = new FileReader();
        reader.onload = (e) => {
            const img = new Image();
            img.onload = () => {
                const canvas = document.createElement('canvas');
                let width = img.width, height = img.height;
                if (width > maxWidth) { height = Math.round((height * maxWidth) / width); width = maxWidth; }
                canvas.width = width; canvas.height = height;
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
