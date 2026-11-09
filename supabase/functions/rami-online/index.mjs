import { createServer } from 'node:http';
import { WebSocketServer } from 'npm:ws@8.22.0';
import { GameHub } from '../../../vercel/lib/hub.mjs';
import { SupabaseRoomStore } from './store.mjs';
import { SupabaseVoice } from './voice.mjs';

// Anonymous players enter with an invitation code. Each seat then authenticates
// with its own 192-bit bearer token inside the encrypted WebSocket, never a URL.
// Database/admin keys are read only from Supabase's injected environment.
const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}');
const store = new SupabaseRoomStore({
  url: Deno.env.get('SUPABASE_URL'),
  secretKey: keys.default || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
});
const voice = new SupabaseVoice({ url: Deno.env.get('SUPABASE_URL'), secretKey: keys.default || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') });
const hub = new GameHub(store, { preserveLobby: true, voice });
const initialization = hub.start();
initialization.catch(() => console.error('Rami storage initialization failed'));
const server = createServer(async (_request, response) => {
  let ready = false;
  try { await initialization; await store.ready(); ready = true; } catch { /* Honest 503, no memory-only games. */ }
  response.writeHead(ready ? 200 : 503, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
  response.end(JSON.stringify({ service: 'Rami Salon 3D', version: '0.12.0', ready, protocol: 1, storage: 'supabase-postgres', variants: ['rami', 'tri6', 'tri12'], features: ['player-count', 'tri-multiplayer', 'rematch', 'voice', 'series', 'tournaments', 'province', 'kick'] }));
});
const wss = new WebSocketServer({ noServer: true, maxPayload: 32768, perMessageDeflate: false });
let pendingUpgrades = 0;
server.on('upgrade', async (_request, socket, head) => {
  if (pendingUpgrades + hub.entries.size >= 256) {
    socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    return;
  }
  pendingUpgrades++;
  try {
    await initialization;
    if (socket.destroyed) return;
    wss.handleUpgrade(_request, socket, head, ws => {
      hub.attach(ws);
      // Rotate before the free-plan worker limit. The client automatically
      // resumes the same persistent seat, including while waiting in the lobby.
      const rotation = setTimeout(() => ws.close(1012, 'Reconnexion automatique'), 100000);
      rotation.unref?.();
      const lifetime = new Promise(resolve => ws.once('close', () => { clearTimeout(rotation); resolve(); }));
      if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(lifetime);
    });
  } catch {
    if (!socket.destroyed) socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
  } finally { pendingUpgrades--; }
});
server.listen(8080);
