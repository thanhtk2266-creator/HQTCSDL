const CACHE = 'aurora-week1-shell-v5';
const APP_SHELL = [
  '/',
  '/index.html',
  '/style.css',
  '/app-root.js',
  '/app.js',
  '/vendor/react.production.min.js',
  '/vendor/react-dom.production.min.js',
  '/manifest.webmanifest',
  '/icons/aurora-192.png',
  '/icons/aurora-512.png',
];
const APP_SHELL_PATHS = new Set(APP_SHELL);

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE).then(cache => cache.addAll(APP_SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key.startsWith('aurora-week1-shell-') && key !== CACHE).map(key => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return;
  if (url.search || !APP_SHELL_PATHS.has(url.pathname)) return;

  event.respondWith((async () => {
    const cached = await caches.match(request);
    try {
      const response = await fetch(request);
      if (response.ok) {
        const cache = await caches.open(CACHE);
        await cache.put(request, response.clone());
      }
      return response;
    } catch {
      return cached || (request.mode === 'navigate' ? await caches.match('/') : Response.error());
    }
  })());
});
