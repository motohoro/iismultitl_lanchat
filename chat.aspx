<%@ Page Language="C#" AutoEventWireup="true" %>
<%@ Import Namespace="System.Collections.Generic" %>
<%@ Import Namespace="System.Linq" %>
<%@ Import Namespace="System.Web.Script.Serialization" %>
<%@ Import Namespace="System.IO" %>

<script runat="server">
    // メモリ保持用クラス
    public class ThreadInfo {
        public string id { get; set; }
        public string title { get; set; }
        public string createTime { get; set; }
        public string lastMsgTime { get; set; } // 最終受信日時 (表示用)
        public DateTime updatedAt { get; set; }  // ソート基準用
    }

    public class MsgInfo {
        public string threadId { get; set; }
        public string user { get; set; }
        public string text { get; set; }
        public string image { get; set; }
        public string time { get; set; }
    }

    // サーバー起動中・電源が切れるまでメモリに保持
    private static readonly List<ThreadInfo> threads = new List<ThreadInfo>() {
        new ThreadInfo { 
            id = "tl_1", 
            title = "メインタイムライン", 
            createTime = DateTime.Now.ToString("HH:mm"),
            lastMsgTime = "メッセージなし",
            updatedAt = DateTime.Now
        }
    };
    private static readonly List<MsgInfo> messages = new List<MsgInfo>();
    private static readonly object lockObj = new object();

    protected void Page_Load(object sender, EventArgs e)
    {
        string action = Request.QueryString["action"];
        if (string.IsNullOrEmpty(action)) return;

        JavaScriptSerializer serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = int.MaxValue;

        // APIルーティング
        if (action == "get_threads")
        {
            Response.ContentType = "application/json; charset=utf-8";
            lock (lockObj) {
                // 最新メッセージ（または作成日時）が新しい順に並べ替えて返却
                var sortedThreads = threads.OrderByDescending(t => t.updatedAt).ToList();
                Response.Write(serializer.Serialize(sortedThreads));
            }
            Response.End();
        }
        else if (action == "create_thread" && Request.HttpMethod == "POST")
        {
            string body = GetRequestBody();
            var data = serializer.Deserialize<Dictionary<string, string>>(body);
            if (data != null && data.ContainsKey("title") && !string.IsNullOrEmpty(data["title"])) {
                DateTime now = DateTime.Now;
                lock (lockObj) {
                    threads.Add(new ThreadInfo {
                        id = "tl_" + Guid.NewGuid().ToString().Substring(0, 8),
                        title = data["title"],
                        createTime = now.ToString("HH:mm"),
                        lastMsgTime = "メッセージなし",
                        updatedAt = now
                    });
                }
            }
            Response.ContentType = "application/json; charset=utf-8";
            Response.Write("{\"status\":\"ok\"}");
            Response.End();
        }
        else if (action == "get_messages")
        {
            string threadId = Request.QueryString["threadId"];
            Response.ContentType = "application/json; charset=utf-8";
            lock (lockObj) {
                var filtered = messages.FindAll(m => m.threadId == threadId);
                Response.Write(serializer.Serialize(filtered));
            }
            Response.End();
        }
        else if (action == "send" && Request.HttpMethod == "POST")
        {
            string body = GetRequestBody();
            var data = serializer.Deserialize<Dictionary<string, string>>(body);
            if (data != null && data.ContainsKey("threadId")) {
                DateTime now = DateTime.Now;
                string timeStr = now.ToString("HH:mm");

                lock (lockObj) {
                    // メッセージ追加
                    messages.Add(new MsgInfo {
                        threadId = data["threadId"],
                        user = data.ContainsKey("user") && !string.IsNullOrEmpty(data["user"]) ? data["user"] : "Anonymous",
                        text = data.ContainsKey("text") ? data["text"] : "",
                        image = data.ContainsKey("image") ? data["image"] : "",
                        time = timeStr
                    });

                    // 該当スレッドの最新更新日時と最終受信表示を更新
                    var targetTL = threads.Find(t => t.id == data["threadId"]);
                    if (targetTL != null) {
                        targetTL.lastMsgTime = timeStr;
                        targetTL.updatedAt = now;
                    }
                }
            }
            Response.ContentType = "application/json; charset=utf-8";
            Response.Write("{\"status\":\"ok\"}");
            Response.End();
        }
    }

    private string GetRequestBody() {
        using (var reader = new StreamReader(Request.InputStream, Request.ContentEncoding)) {
            return reader.ReadToEnd();
        }
    }
</script>

<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<title>IIS Multi TL LAN Chat</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 10px; background: #7494c0; }
  
  .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px; background: #ffffff; padding: 10px 14px; border-radius: 12px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
  .header h2 { margin: 0; font-size: 1rem; color: #222; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 160px; }
  .header-controls { display: flex; align-items: center; gap: 8px; }
  .header input { padding: 5px 8px; border: 1px solid #ccc; border-radius: 10px; font-size: 13px; text-align: center; width: 75px; }
  
  .btn-action { background: #007aff; color: white; border: none; border-radius: 16px; padding: 6px 12px; font-size: 13px; font-weight: bold; cursor: pointer; }
  .btn-back { background: #e5e5ea; color: #007aff; border: none; border-radius: 16px; padding: 6px 12px; font-size: 13px; font-weight: bold; cursor: pointer; display: none; }

  #tl-list-view { display: block; height: calc(100vh - 80px); overflow-y: auto; }
  .tl-card { background: #ffffff; border-radius: 12px; padding: 14px; margin-bottom: 10px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); cursor: pointer; display: flex; justify-content: space-between; align-items: center; }
  .tl-card:active { background: #f0f0f0; }
  .tl-title { font-weight: bold; font-size: 16px; color: #333; margin-bottom: 4px; }
  .tl-meta { font-size: 12px; color: #666; }
  .tl-badge { font-weight: bold; color: #007aff; }
  .tl-arrow { font-size: 18px; color: #ccc; font-weight: bold; margin-left: 10px; }

  #tl-detail-view { display: none; flex-direction: column; height: calc(100vh - 80px); }
  #chat { flex: 1; overflow-y: auto; padding: 10px 0; display: flex; flex-direction: column; gap: 10px; }
  
  .msg-row { display: flex; flex-direction: column; max-width: 80%; }
  .msg-row.me { align-self: flex-end; align-items: flex-end; }
  .msg-row.other { align-self: flex-start; align-items: flex-start; }
  .user-name { font-size: 0.72rem; color: #ffffff; margin-bottom: 3px; padding: 0 4px; text-shadow: 0 1px 2px rgba(0,0,0,0.3); }
  .bubble { padding: 10px 14px; border-radius: 16px; font-size: 15px; word-break: break-word; box-shadow: 0 1px 2px rgba(0,0,0,0.15); }
  .me .bubble { background: #85e249; color: #000; border-top-right-radius: 2px; }
  .other .bubble { background: #ffffff; color: #000; border-top-left-radius: 2px; }
  .chat-img { max-width: 100%; max-height: 250px; border-radius: 10px; margin-top: 6px; display: block; cursor: pointer; object-fit: cover; }
  .time { font-size: 0.65rem; color: #666; text-align: right; margin-top: 4px; }
  .me .time { color: #335500; }
  
  #preview-bar { display: none; background: #fff; padding: 8px 12px; border-radius: 10px 10px 0 0; align-items: center; gap: 10px; font-size: 12px; }
  #preview-img { height: 40px; border-radius: 6px; object-fit: cover; }
  .cancel-btn { background: #ff4d4d; color: white; border: none; border-radius: 50%; width: 22px; height: 22px; font-weight: bold; cursor: pointer; }
  
  #input-bar { display: flex; gap: 6px; background: #fff; padding: 8px; border-radius: 24px; box-shadow: 0 2px 6px rgba(0,0,0,0.2); }
  #msgText { flex: 1; border: none; outline: none; padding: 8px 12px; font-size: 15px; background: transparent; }
  .icon-btn { background: #f0f0f0; border: none; border-radius: 50%; width: 38px; height: 38px; display: flex; align-items: center; justify-content: center; font-size: 18px; cursor: pointer; flex-shrink: 0; }
  .send-btn { background: #007aff; color: white; border: none; border-radius: 19px; padding: 0 16px; font-weight: bold; font-size: 14px; cursor: pointer; flex-shrink: 0; }
  
  #modal { display: none; position: fixed; top:0; left:0; width:100%; height:100%; background: rgba(0,0,0,0.85); justify-content: center; align-items: center; z-index: 999; }
  #modal img { max-width: 90%; max-height: 90%; border-radius: 8px; }
</style>
</head>
<body>

<div class="header">
  <button id="btnBack" class="btn-back" onclick="showTLList()">← 一覧</button>
  <h2 id="headerTitle">タイムライン一覧</h2>
  <div class="header-controls">
    <input type="text" id="username" value="User">
    <button id="btnAddTL" class="btn-action" onclick="createTL()">＋ 作成</button>
  </div>
</div>

<div id="tl-list-view"></div>

<div id="tl-detail-view">
  <div id="chat"></div>

  <div id="preview-bar">
    <img id="preview-img" src="">
    <span>画像添付あり</span>
    <button class="cancel-btn" onclick="clearImage()">×</button>
  </div>

  <div id="input-bar">
    <label class="icon-btn" title="画像を添付">
      📷
      <input type="file" id="imgInput" accept="image/*" style="display:none;" onchange="handleFileSelect(event)">
    </label>
    <input type="text" id="msgText" placeholder="メッセージを入力..." onkeydown="if(event.key==='Enter') sendMsg()">
    <button class="send-btn" onclick="sendMsg()">送信</button>
  </div>
</div>

<div id="modal" onclick="this.style.display='none'">
  <img id="modal-img" src="">
</div>

<script>
let currentTLId = null;
let currentTLTitle = '';
let currentBase64 = '';
let lastThreadJson = '';
let lastMsgJson = '';

// 着信音 (Web Audio API)
let audioCtx = null;
function initAudio() {
  if (!audioCtx) audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  if (audioCtx.state === 'suspended') audioCtx.resume();
}
document.addEventListener('click', initAudio, { passive: true });
document.addEventListener('touchstart', initAudio, { passive: true });

function playNotificationSound() {
  if (!audioCtx) return;
  try {
    if (audioCtx.state === 'suspended') audioCtx.resume();
    const now = audioCtx.currentTime;
    
    const osc1 = audioCtx.createOscillator();
    const gain1 = audioCtx.createGain();
    osc1.type = 'sine';
    osc1.frequency.setValueAtTime(880, now);
    gain1.gain.setValueAtTime(0.15, now);
    gain1.gain.exponentialRampToValueAtTime(0.001, now + 0.12);
    osc1.connect(gain1);
    gain1.connect(audioCtx.destination);
    osc1.start(now); osc1.stop(now + 0.12);

    const osc2 = audioCtx.createOscillator();
    const gain2 = audioCtx.createGain();
    osc2.type = 'sine';
    osc2.frequency.setValueAtTime(1318.51, now + 0.08);
    gain2.gain.setValueAtTime(0.2, now + 0.08);
    gain2.gain.exponentialRampToValueAtTime(0.001, now + 0.28);
    osc2.connect(gain2);
    gain2.connect(audioCtx.destination);
    osc2.start(now + 0.08); osc2.stop(now + 0.28);
  } catch(e) {}
}

function showTLList() {
  currentTLId = null;
  document.getElementById('tl-list-view').style.display = 'block';
  document.getElementById('tl-detail-view').style.display = 'none';
  document.getElementById('btnBack').style.display = 'none';
  document.getElementById('btnAddTL').style.display = 'block';
  document.getElementById('headerTitle').textContent = 'タイムライン一覧';
  fetchThreads();
}

function openTL(id, title) {
  currentTLId = id;
  currentTLTitle = title;
  document.getElementById('tl-list-view').style.display = 'none';
  document.getElementById('tl-detail-view').style.display = 'flex';
  document.getElementById('btnBack').style.display = 'block';
  document.getElementById('btnAddTL').style.display = 'none';
  document.getElementById('headerTitle').textContent = title;
  lastMsgJson = '';
  fetchMessages();
}

async function createTL() {
  const title = prompt('新しいタイムラインのタイトルを入力してください:');
  if (!title || !title.trim()) return;
  
  await fetch('chat.aspx?action=create_thread', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ title: title.trim() })
  });
  fetchThreads();
}

async function fetchThreads() {
  if (currentTLId !== null) return;
  try {
    const res = await fetch('chat.aspx?action=get_threads');
    const jsonText = await res.text();
    if (jsonText === lastThreadJson) return;
    
    // スレッド追加や更新時に音を鳴らす
    if (lastThreadJson !== '') {
      playNotificationSound();
    }
    
    lastThreadJson = jsonText;
    const threads = JSON.parse(jsonText);
    const container = document.getElementById('tl-list-view');
    container.innerHTML = '';
    
    threads.forEach(t => {
      const card = document.createElement('div');
      card.className = 'tl-card';
      card.onclick = () => openTL(t.id, t.title);
      card.innerHTML = `
        <div>
          <div class="tl-title">${t.title}</div>
          <div class="tl-meta">最終受信: <span class="tl-badge">${t.lastMsgTime}</span> (作成 ${t.createTime})</div>
        </div>
        <div class="tl-arrow">❯</div>
      `;
      container.appendChild(card);
    });
  } catch(e) {}
}

async function fetchMessages() {
  if (!currentTLId) return;
  try {
    const res = await fetch('chat.aspx?action=get_messages&threadId=' + currentTLId);
    const jsonText = await res.text();
    if (jsonText === lastMsgJson) return;
    
    const data = JSON.parse(jsonText);
    const me = document.getElementById('username').value;
    
    if (lastMsgJson !== '') {
      const oldMsgs = JSON.parse(lastMsgJson);
      if (data.length > oldMsgs.length) {
        const lastMsg = data[data.length - 1];
        if (lastMsg.user !== me) playNotificationSound();
      }
    }
    
    lastMsgJson = jsonText;
    const chat = document.getElementById('chat');
    chat.innerHTML = '';
    
    data.forEach(m => {
      const isMe = m.user === me;
      const row = document.createElement('div');
      row.className = 'msg-row ' + (isMe ? 'me' : 'other');
      
      const uDiv = document.createElement('div');
      uDiv.className = 'user-name';
      uDiv.textContent = m.user;
      row.appendChild(uDiv);
      
      const bubble = document.createElement('div');
      bubble.className = 'bubble';
      
      if (m.text) {
        const textSpan = document.createElement('div');
        textSpan.textContent = m.text;
        bubble.appendChild(textSpan);
      }
      
      if (m.image) {
        const imgEl = document.createElement('img');
        imgEl.className = 'chat-img';
        imgEl.src = m.image;
        imgEl.onclick = () => {
          document.getElementById('modal-img').src = m.image;
          document.getElementById('modal').style.display = 'flex';
        };
        bubble.appendChild(imgEl);
      }
      
      const timeDiv = document.createElement('div');
      timeDiv.className = 'time';
      timeDiv.textContent = m.time;
      bubble.appendChild(timeDiv);
      
      row.appendChild(bubble);
      chat.appendChild(row);
    });
    
    chat.scrollTop = chat.scrollHeight;
  } catch(e) {}
}

function handleFileSelect(e) {
  const file = e.target.files[0];
  if (!file) return;
  
  const reader = new FileReader();
  reader.onload = function(evt) {
    const img = new Image();
    img.onload = function() {
      const canvas = document.createElement('canvas');
      let w = img.width, h = img.height;
      const maxDim = 1000;
      if (w > maxDim || h > maxDim) {
        if (w > h) { h = Math.round((h * maxDim) / w); w = maxDim; }
        else { w = Math.round((w * maxDim) / h); h = maxDim; }
      }
      canvas.width = w; canvas.height = h;
      const ctx = canvas.getContext('2d');
      ctx.drawImage(img, 0, 0, w, h);
      currentBase64 = canvas.toDataURL('image/jpeg', 0.75);
      
      document.getElementById('preview-img').src = currentBase64;
      document.getElementById('preview-bar').style.display = 'flex';
    };
    img.src = evt.target.result;
  };
  reader.readAsDataURL(file);
}

function clearImage() {
  currentBase64 = '';
  document.getElementById('imgInput').value = '';
  document.getElementById('preview-bar').style.display = 'none';
}

async function sendMsg() {
  const textInput = document.getElementById('msgText');
  const user = document.getElementById('username').value || 'Anonymous';
  const text = textInput.value.trim();
  const image = currentBase64;
  
  if (!text && !image) return;
  
  textInput.value = '';
  clearImage();
  
  await fetch('chat.aspx?action=send', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ threadId: currentTLId, user, text, image })
  });
  
  fetchMessages();
}

setInterval(() => {
  if (currentTLId === null) fetchThreads();
  else fetchMessages();
}, 1000);

showTLList();
</script>
</body>
</html>
