const CACHE = 'ant-streams-theme-v4';
const ASSETS = ['./', './index.html', './theme.css', './manifest.webmanifest', './icon.svg', './icon-180.png', './icon-192.png', './icon-512.png'];
self.addEventListener('install', event => event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(ASSETS)).then(() => self.skipWaiting())));
self.addEventListener('activate', event => event.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(key => (key.startsWith('rigatoni-') || key.startsWith('ant-streams-')) && key !== CACHE).map(key => caches.delete(key)))).then(() => self.clients.claim())));
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  // Only static app assets belong in the cache. Never cache provider requests,
  // account callbacks, auth sessions, or decrypted vault responses.
  if (event.request.method !== 'GET' || url.origin !== self.location.origin || url.search || url.hash) return;
  const asset = ASSETS.find(path => new URL(path, self.registration.scope).href === url.href);
  if (!asset) return;
  event.respondWith(fetch(event.request).then(response => {
    if (response.ok) { const copy = response.clone(); caches.open(CACHE).then(cache => cache.put(event.request, copy)); }
    return response;
  }).catch(() => caches.match(event.request)));
});
