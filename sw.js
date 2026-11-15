/* Catcul Service Worker — offline shell cache, background call & message push, and laptop inline notification replies. */
const CACHE = 'catcul-shell-v41';
const SHELL = [
  './',
  './index.html',
  './catcul.html',
  './signin.html',
  './signup.html',
  './guest.html',
  './help.html',
  './tutorial.html',
  './terms.html',
  './privacy.html',
  './refund.html',
  './manifest.json',
  './icons/catcul-192.png',
  './icons/catcul-512.png'
];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE).then(cache => Promise.all(SHELL.map(u => cache.add(u).catch(() => null)))).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req).then(res => {
        if (res.ok && !res.redirected) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        }
        return res;
      }).catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match('./catcul.html')))
    );
    return;
  }
  if (url.pathname.includes('/wallpapers/')) {
    event.respondWith(
      caches.match(req).then(cached => cached || fetch(req).then(res => {
        if (res.ok) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {});
        }
        return res;
      }))
    );
    return;
  }
  if (SHELL.some(p => url.pathname.endsWith(p.replace('./', '/')))) {
    event.respondWith(caches.match(req).then(r => r || fetch(req)));
  }
});

async function showSafeNotification(title, options) {
  try {
    return await self.registration.showNotification(title, options);
  } catch {
    const fallback = { ...options };
    if (Array.isArray(fallback.actions)) {
      fallback.actions = fallback.actions.map(a => ({ action: a.action, title: a.title }));
    }
    return await self.registration.showNotification(title, fallback);
  }
}

self.addEventListener('push', event => {
  let payload = {};
  try { payload = event.data ? event.data.json() : {}; } catch { payload = { body: event.data?.text() || '' }; }
  const isCall = payload.kind === 'call';
  const title = String(payload.title || 'Catcul').slice(0, 80);
  const roomId = String(payload.roomId || '');
  const callId = String(payload.callId || '');
  const messageId = String(payload.messageId || '');
  const url = String(payload.url || (roomId ? `./catcul.html?room=${encodeURIComponent(roomId)}` : './catcul.html'));
  const options = {
    body: String(payload.body || (isCall ? 'Incoming call on Catcul' : 'You have a new message.')).slice(0, 180),
    icon: './icons/catcul-192.png',
    badge: './icons/catcul-192.png',
    tag: String(payload.tag || (isCall ? `catcul-call-${callId || 'ring'}` : `catcul-msg-${roomId || 'general'}`)).slice(0, 64),
    renotify: true,
    requireInteraction: isCall,
    data: {
      kind: isCall ? 'call' : 'message',
      roomId,
      callId,
      messageId,
      url
    },
    actions: isCall
      ? [
          { action: 'answer-call', title: 'Answer' },
          { action: 'decline-call', title: 'Decline' },
          { action: 'reply-call', type: 'text', title: 'Reply', placeholder: 'Send a quick message…' }
        ]
      : [
          { action: 'reply-message', type: 'text', title: 'Reply', placeholder: 'Write a reply…' },
          { action: 'open-chat', title: 'Open chat' }
        ]
  };
  event.waitUntil(showSafeNotification(title, options));
});

self.addEventListener('notificationclick', event => {
  const rawAction = event.action || '';
  const action = rawAction === 'answer' ? 'answer-call' : rawAction === 'decline' ? 'decline-call' : rawAction === 'reply' ? (event.notification?.data?.kind === 'call' ? 'reply-call' : 'reply-message') : rawAction;
  const replyText = typeof event.reply === 'string' ? event.reply.trim() : '';
  const data = event.notification.data || {};
  const roomId = String(data.roomId || '');
  const callId = String(data.callId || '');
  const messageId = String(data.messageId || '');
  event.notification.close();

  event.waitUntil((async () => {
    const list = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const appClient = list.find(c => {
      try {
        const u = new URL(c.url);
        return u.origin === self.location.origin && (u.pathname.endsWith('/catcul.html') || u.pathname === '/' || u.pathname.endsWith('/index.html'));
      } catch { return false; }
    });
    const workspaceClient = list.find(c => {
      try { return new URL(c.url).origin === self.location.origin && new URL(c.url).pathname.endsWith('/catcul.html'); } catch { return false; }
    });

    if ((action === 'reply-message' || action === 'reply-call') && replyText) {
      if (workspaceClient) {
        workspaceClient.postMessage({
          type: 'CATCUL_SW_ACTION',
          kind: 'inline-reply',
          roomId,
          callId: action === 'reply-call' ? callId : '',
          messageId,
          text: replyText
        });
        return;
      }
      const u = new URL('./catcul.html', self.location.origin);
      if (roomId) u.searchParams.set('room', roomId);
      if (messageId) u.searchParams.set('reply_to', messageId);
      if (action === 'reply-call' && callId) u.searchParams.set('decline_call', callId);
      u.searchParams.set('autosend', replyText);
      if (self.clients.openWindow) await self.clients.openWindow(u.href);
      return;
    }

    if (action === 'decline-call' && callId) {
      if (workspaceClient) {
        workspaceClient.postMessage({ type: 'CATCUL_SW_ACTION', kind: 'decline-call', roomId, callId });
        return;
      }
      const u = new URL('./catcul.html', self.location.origin);
      if (roomId) u.searchParams.set('room', roomId);
      u.searchParams.set('decline_call', callId);
      if (self.clients.openWindow) await self.clients.openWindow(u.href);
      return;
    }

    if (action === 'answer-call' && callId) {
      if (workspaceClient) {
        await workspaceClient.focus().catch(() => {});
        workspaceClient.postMessage({ type: 'CATCUL_SW_ACTION', kind: 'answer-call', roomId, callId });
        return;
      }
      const u = new URL('./catcul.html', self.location.origin);
      if (roomId) u.searchParams.set('room', roomId);
      u.searchParams.set('accept_call', callId);
      if (self.clients.openWindow) await self.clients.openWindow(u.href);
      return;
    }

    if (action === 'reply-message' || action === 'reply-call') {
      if (workspaceClient) {
        await workspaceClient.focus().catch(() => {});
        workspaceClient.postMessage({ type: 'CATCUL_SW_ACTION', kind: 'open-reply', roomId, callId, messageId });
        return;
      }
      const u = new URL('./catcul.html', self.location.origin);
      if (roomId) u.searchParams.set('room', roomId);
      if (messageId) u.searchParams.set('reply_to', messageId);
      if (self.clients.openWindow) await self.clients.openWindow(u.href);
      return;
    }

    const targetUrl = String(data.url || (roomId ? `./catcul.html?room=${encodeURIComponent(roomId)}` : './catcul.html'));
    const fullTarget = new URL(targetUrl, self.location.origin).href;
    if (workspaceClient) {
      await workspaceClient.focus().catch(() => {});
      if (roomId) workspaceClient.postMessage({ type: 'CATCUL_SW_ACTION', kind: 'open-reply', roomId, messageId });
      return;
    }
    if (appClient && 'navigate' in appClient) {
      await appClient.navigate(fullTarget).catch(() => {});
      await appClient.focus().catch(() => {});
      return;
    }
    if (self.clients.openWindow) await self.clients.openWindow(fullTarget);
  })());
});
