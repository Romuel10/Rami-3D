import { createGameServer } from '../lib/server.mjs';
// Vercel's native WebSocket support accepts a standard Node HTTP server.
// Each invocation shares only durable Redis state, never a process-local room.
const application = createGameServer();
export default application.server;
