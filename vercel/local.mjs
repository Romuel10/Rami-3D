import { createGameServer } from './lib/server.mjs';
const port = Number(process.env.PORT || 7357);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('PORT invalide.');
const app = createGameServer();
try {
  await app.ready;
  app.server.listen(port, '0.0.0.0', () => console.log(`RAMI_VERCEL_READY port=${port}`));
} catch {
  console.error('Redis indisponible. Vérifiez REDIS_URL et la connexion du stockage.');
  await app.close();
  process.exitCode = 1;
}
for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, async () => { await app.close(); process.exit(); });
