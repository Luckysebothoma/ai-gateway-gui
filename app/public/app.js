(() => {
  const fulldate = document.getElementById('fulldate');
  const statusBadge = document.getElementById('statusBadge');
  const newChatBtn = document.getElementById('newChatBtn');
  const messagesEl = document.getElementById('messages');
  const composer = document.getElementById('composer');
  const messageInput = document.getElementById('messageInput');
  const sendBtn = document.getElementById('sendBtn');

  let sessionId = localStorage.getItem('ai_gui_session_id') || null;
  let sending = false;

  function renderFullDate() {
    const now = new Date();
    fulldate.textContent = now.toLocaleDateString(undefined, { weekday:'long', year:'numeric', month:'long', day:'numeric' }) + ' — ' + now.toLocaleTimeString();
  }
  renderFullDate(); setInterval(renderFullDate, 30000);

  // Every fetch response goes through this. Never call res.json() directly
  // on an unchecked response -- if the server (or a proxy in front of it)
  // ever returns HTML or plain text, this throws a clear, handled error
  // instead of a cryptic "unexpected character" crash.
  async function fetchJson(url, options) {
    const res = await fetch(url, options);
    const raw = await res.text();
    let data;
    try {
      data = raw ? JSON.parse(raw) : {};
    } catch (e) {
      throw new Error(`Server returned non-JSON (HTTP ${res.status}): ${raw.slice(0, 120)}`);
    }
    if (!res.ok && data && data.error) {
      throw new Error(data.error.message || `HTTP ${res.status}`);
    }
    if (!res.ok) {
      throw new Error(`HTTP ${res.status}`);
    }
    return data;
  }

  function addMessage(role, content, meta) {
    const el = document.createElement('div');
    el.className = `msg msg--${role}`;
    el.textContent = content;
    if (meta) {
      const metaEl = document.createElement('span');
      metaEl.className = 'msg__meta';
      metaEl.textContent = meta;
      el.appendChild(metaEl);
    }
    messagesEl.appendChild(el);
    messagesEl.scrollTop = messagesEl.scrollHeight;
    return el;
  }

  function addTyping() {
    const el = document.createElement('div');
    el.className = 'msg msg--assistant';
    el.innerHTML = '<span class="typing"><span></span><span></span><span></span></span>';
    messagesEl.appendChild(el);
    messagesEl.scrollTop = messagesEl.scrollHeight;
    return el;
  }

  async function ensureSession() {
    if (sessionId) return sessionId;
    statusBadge.textContent = 'starting…';
    const data = await fetchJson('/api/session/start', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}),
    });
    sessionId = data.session_id;
    localStorage.setItem('ai_gui_session_id', sessionId);
    return sessionId;
  }

  async function loadHistory() {
    if (!sessionId) return;
    try {
      const data = await fetchJson(`/api/conversations/${encodeURIComponent(sessionId)}/messages`);
      messagesEl.innerHTML = '';
      for (const m of data.messages || []) {
        if (m.role === 'user' || m.role === 'assistant') addMessage(m.role, m.content);
      }
    } catch (e) {
      // Non-fatal -- a fresh session just has no history yet.
    }
  }

  async function checkStatus() {
    try {
      const data = await fetchJson('/api/dependencies');
      const anyUp = Object.values(data).some((d) => d && d.available);
      statusBadge.textContent = anyUp ? 'gateway online' : 'gateway unreachable';
    } catch (e) {
      statusBadge.textContent = 'status unknown';
    }
  }

  async function sendMessage(text) {
    if (sending) return;
    sending = true;
    sendBtn.disabled = true;
    addMessage('user', text);
    const typingEl = addTyping();
    try {
      const sid = await ensureSession();
      const data = await fetchJson('/api/chat', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ session_id: sid, message: text }),
      });
      typingEl.remove();
      addMessage('assistant', data.response, data.provider ? `via ${data.provider}` : null);
      if (data.context_degraded) {
        addMessage('system', 'Note: conversation context may be degraded right now.');
      }
    } catch (e) {
      typingEl.remove();
      addMessage('error', `Something went wrong: ${e.message}`);
    } finally {
      sending = false;
      sendBtn.disabled = false;
      messageInput.focus();
    }
  }

  composer.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = messageInput.value.trim();
    if (!text) return;
    messageInput.value = '';
    sendMessage(text);
  });

  newChatBtn.addEventListener('click', () => {
    sessionId = null;
    localStorage.removeItem('ai_gui_session_id');
    messagesEl.innerHTML = '';
    addMessage('system', 'Started a new conversation.');
  });

  (async () => {
    checkStatus();
    setInterval(checkStatus, 30000);
    if (sessionId) await loadHistory();
    if (!messagesEl.children.length) addMessage('system', 'Say hello to get started.');
    messageInput.focus();
  })();
})();
