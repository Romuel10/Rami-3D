import http from 'node:http';
import { WebSocketServer } from 'ws';
import { RedisRoomStore } from './store.mjs';
import { GameHub } from './hub.mjs';

export function createGameServer({ redisUrl = process.env.REDIS_URL, prefix = process.env.RAMI_REDIS_PREFIX || 'rami:v1:', ...timings } = {}) {
  let ready = false;
  let store, hub;
  let pendingUpgrades = 0;
  async function waitForReady() {
    let timer;
    try {
      await Promise.race([initialization,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Redis startup timeout')),5000); timer.unref?.();})]);
      return ready && store?.redis.status === 'ready' && hub?.subscriber?.status === 'ready';
    } catch { return false; }
    finally { clearTimeout(timer); }
  }
  const server = http.createServer(async (request, response) => {
    const available = await waitForReady();
    if(response.destroyed) return;
    response.setHeader('Content-Type', 'application/json; charset=utf-8');
    response.setHeader('Cache-Control', 'no-store');
    response.statusCode = available ? 200 : 503;
    response.end(JSON.stringify({ service: 'Rami Salon 3D', ready: available, websocket: '/api/ws', protocol: 1, message: available ? 'Serveur prêt.' : 'Stockage Redis à configurer ou indisponible.' }));
  });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 32768, perMessageDeflate: false });
  server.on('upgrade', async (request, socket, head) => {
    const path = new URL(request.url, 'http://localhost').pathname;
    if (path !== '/api/ws' || pendingUpgrades >= 256) {
      socket.end(`HTTP/1.1 ${path !== '/api/ws' ? '404 Not Found' : '503 Service Unavailable'}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
      return;
    }
    pendingUpgrades++;
    try {
      // The first upgrade initializes its own Function instance. Wait for the
      // external store instead of repeatedly rejecting every cold-start client.
      if (!await waitForReady() || hub.entries.size >= 256) {
        if(!socket.destroyed) socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
        return;
      }
      if(!socket.destroyed) wss.handleUpgrade(request, socket, head, ws => hub.attach(ws));
    } finally { pendingUpgrades--; }
  });
  const initialization = (async () => {
    store = new RedisRoomStore(redisUrl, { prefix });
    hub = new GameHub(store, timings);
    await hub.start();
    ready = true;
    return hub;
  })();
  // A missing integration gives an honest 503, never a memory-only public game.
  initialization.catch(() => {});
  return {
    server, wss, get hub() { return hub; }, ready: initialization,
    async close(options) {
      ready = false;
      if (hub) await hub.close(options);
      for (const socket of wss.clients) socket.terminate();
      await new Promise(resolve => wss.close(resolve));
      await new Promise(resolve => server.close(resolve));
    }
  };
}
