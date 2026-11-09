import { randomInt, randomUUID } from 'node:crypto';
import { validateState } from '../../../vercel/lib/engine.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/** Private, durable Postgres storage. Credentials exist only in the worker. */
export class SupabaseRoomStore {
  constructor({ url, secretKey, fetcher = fetch }) {
    if (!url || !secretKey) throw new Error('Supabase server configuration missing');
    this.url = url.replace(/\/$/, '');
    this.secretKey = secretKey;
    this.fetcher = fetcher;
    this.pollUpdates = true;
  }
  async rpc(name, parameters) {
    // New secret keys go on apikey only; legacy service-role JWTs also work.
    const headers = { apikey: this.secretKey, 'Content-Type': 'application/json' };
    if (!this.secretKey.startsWith('sb_secret_')) headers.Authorization = `Bearer ${this.secretKey}`;
    const response = await this.fetcher(`${this.url}/rest/v1/rpc/rami_room_${name}`, {
      method: 'POST', headers, body: JSON.stringify(parameters), signal: AbortSignal.timeout(4000)
    });
    if (!response.ok) throw new Error(`Room storage unavailable (${response.status})`);
    if (response.status === 204) return null;
    return response.json();
  }
  validate(room) {
    const bye = room?.game === null && Number.isInteger(room.tournament?.duels[room.tournament.stage]?.winner);
    if (room?.started && !bye && !validateState(room.game)) throw new Error('Sauvegarde de partie invalide.');
    return room;
  }
  async ready() { await this.rpc('read', { p_code: '000000' }); }
  async read(code) { return this.validate(await this.rpc('read', { p_code: code })); }
  async create(initial) {
    for (let attempt = 0; attempt < 32; attempt++) {
      const now = Date.now();
      const code = String(randomInt(1000000)).padStart(6, '0');
      const room = { ...initial, code, version: 1, created: now, activity: now };
      const status = await this.rpc('create', { p_code: code, p_room: room });
      if (status === 'created') return room;
      if (status === 'full') throw new Error('Le serveur est complet.');
    }
    throw new Error('Impossible de créer un code de salon.');
  }
  async update(code, operation) {
    const token = randomUUID();
    let locked;
    for (let attempt = 0; attempt < 12; attempt++) {
      locked = await this.rpc('lock', { p_code: code, p_lock: token });
      if (locked.status === 'missing') return { room: null, result: null };
      if (locked.status === 'ok') break;
      await sleep(Math.min(40 * (attempt + 1), 200) + randomInt(20));
    }
    if (locked?.status !== 'ok') throw new Error('Salon occupé ; réessayez.');
    let committed = false;
    try {
      const room = this.validate(locked.room);
      const version = room.version;
      const result = await operation(room);
      room.version = version + 1;
      committed = await this.rpc('commit', { p_code: code, p_lock: token, p_version: version, p_room: room });
      if (!committed) throw new Error('Le salon a changé pendant l’action. Réessayez.');
      return { room, result };
    } finally {
      if (!committed) await this.rpc('release', { p_code: code, p_lock: token }).catch(() => {});
    }
  }
  async close() {}
}
