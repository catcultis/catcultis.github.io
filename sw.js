/* Cache only public application files. Never cache Supabase/API/private content.
   Cloudflare Pages & GitHub Pages compatible (handles clean-URL 308 redirects safely). */
const CACHE='catcul-shell-v13';
const FILES=['./','./catcul.html','./signin.html','./signup.html','./manifest.json','./icons/catcul-192.png','./icons/catcul-512.png'];
const ALIASES={'./catcul':'./catcul.html','./signin':'./signin.html','./signup':'./signup.html','./index.html':'./','./index':'./'};
const urls=FILES.map(path=>new URL(path,self.registration.scope).href);
const aliasMap=new Map(Object.entries(ALIASES).map(([k,v])=>[new URL(k,self.registration.scope).href,new URL(v,self.registration.scope).href]));
const cleanRedirect=res=>res.redirected?new Response(res.body,{status:res.status,statusText:res.statusText,headers:res.headers}):res;

self.addEventListener('install',event=>{
  event.waitUntil(caches.open(CACHE).then(cache=>Promise.all(urls.map(u=>fetch(u,{cache:'reload'}).then(res=>{if(!res.ok)throw new Error('Precache failed: '+u);return cache.put(u,cleanRedirect(res));})))));
});
self.addEventListener('activate',event=>{
  event.waitUntil(Promise.all([caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('catcul-shell-')&&k!==CACHE).map(k=>caches.delete(k)))),self.clients.claim()]));
});
self.addEventListener('fetch',event=>{
  const r=event.request,u=new URL(r.url);
  if(r.method!=='GET'||u.origin!==self.location.origin)return;
  u.search='';u.hash='';
  const canonical=aliasMap.get(u.href)||(urls.includes(u.href)?u.href:null);
  if(!canonical)return;
  const netReq=r.mode==='navigate'?fetch(r.url):fetch(r);
  event.respondWith(netReq.then(response=>{
    const safe=cleanRedirect(response);
    if(safe.ok){const clone=safe.clone();caches.open(CACHE).then(c=>c.put(canonical,clone));}
    return safe;
  }).catch(()=>caches.match(canonical).then(cached=>cached||new Response('You are offline. Reconnect to open Catcul.',{status:503,headers:{'Content-Type':'text/plain'}}))));
});
self.addEventListener('push',event=>{let data={};try{data=event.data.json();}catch{}event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(clients=>{if(clients.some(c=>c.visibilityState==='visible'))return;const title=typeof data.title==='string'&&data.title.length<=80?data.title:'Catcul',body=typeof data.body==='string'&&data.body.length<=200?data.body:'A new message is waiting in your room.';return self.registration.showNotification(title,{body,icon:new URL('icons/catcul-192.png',self.registration.scope).href,badge:new URL('icons/catcul-192.png',self.registration.scope).href,tag:typeof data.tag==='string'?data.tag:'catcul-message',data:{room_id:data.room_id},renotify:false});}));});
self.addEventListener('notificationclick',event=>{event.notification.close();const id=event.notification.data?.room_id,u=new URL('catcul.html',self.registration.scope);if(typeof id==='string'&&/^[0-9a-f-]{36}$/.test(id))u.searchParams.set('room',id);event.waitUntil(self.clients.matchAll({type:'window',includeUncontrolled:true}).then(async clients=>{for(const client of clients){if(client.url.startsWith(self.registration.scope)&&'focus' in client){await client.navigate(u.href);return client.focus();}}return self.clients.openWindow(u.href);}));});
self.addEventListener('message',event=>{if(event.data?.type==='CATCUL_SIGNED_OUT')event.waitUntil(self.registration.getNotifications().then(list=>list.forEach(n=>n.close())));});
