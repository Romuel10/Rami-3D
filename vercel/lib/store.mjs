import Redis from 'ioredis';
import { validateState } from './engine.mjs';
import { randomBytes, randomInt } from 'node:crypto';

const releaseScript = "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end";
export const ROOM_TTL_MS = 86400000;
export class RedisRoomStore {
  constructor(url, { prefix = 'rami:v1:', maxRooms = 64 } = {}) {
    if (!url) throw new Error('REDIS_URL doit être configurée côté serveur.');
    this.prefix = prefix;
    this.maxRooms = maxRooms;
    this.redis = new Redis(url, { lazyConnect: true, maxRetriesPerRequest: 1, connectTimeout: 5000, retryStrategy: attempt => Math.min(attempt * 200, 2000) });
    this.redis.on('error', () => {}); // Never log a credential-bearing connection URL.
  }
  key(code) { return `${this.prefix}room:${code}`; }
  get channel() { return `${this.prefix}updates`; }
  async ready() { if (this.redis.status === 'wait') await this.redis.connect(); await this.redis.ping(); }
  async read(code) {
    const data = await this.redis.get(this.key(code));
    if(!data) return null;
    const room = JSON.parse(data);
    if(room.started && !validateState(room.game)) throw new Error('Sauvegarde de partie invalide.');
    return room;
  }
  async lock(code, operation) {
    const key = `${this.prefix}lock:${code}`;
    const token = randomBytes(16).toString('hex');
    let acquired = false;
    for (let attempt = 0; attempt < 80; attempt++) {
      if (await this.redis.set(key, token, 'PX', 5000, 'NX') === 'OK') { acquired = true; break; }
      await new Promise(resolve => setTimeout(resolve, 12 + randomInt(10)));
    }
    if (!acquired) throw new Error('Salon occupé ; réessayez.');
    try { return await operation({ lockKey:key, lockToken:token }); }
    finally { await this.redis.eval(releaseScript, 1, key, token); }
  }
  async create(initial) {
    for (let attempt = 0; attempt < 32; attempt++) {
      const now = Date.now();
      const code = String(randomInt(1000000)).padStart(6, '0');
      const room = { ...initial, code, version: 1, created: now, activity: now };
      const lua = `redis.call('zremrangebyscore',KEYS[1],'-inf',ARGV[1]-ARGV[2]);
        if redis.call('zcard',KEYS[1])>=tonumber(ARGV[3]) then return -1 end;
        if redis.call('exists',KEYS[2])==1 then return 0 end;
        redis.call('set',KEYS[2],ARGV[4],'PX',ARGV[2]);
        redis.call('zadd',KEYS[1],ARGV[1],ARGV[5]); redis.call('publish',ARGV[6],ARGV[5]); return 1`;
      const result = await this.redis.eval(lua,2,`${this.prefix}rooms`,this.key(code),now,ROOM_TTL_MS,this.maxRooms,JSON.stringify(room),code,this.channel);
      if (result === -1) throw new Error('Le serveur est complet.');
      if (result === 1) return room;
    }
    throw new Error('Impossible de créer un code de salon.');
  }
  async update(code, operation, { publish = true } = {}) {
    return this.lock(code, async ({lockKey,lockToken}) => {
      const room = await this.read(code);
      if (!room) return { room: null, result: null };
      if (Date.now() - room.activity > ROOM_TTL_MS) {
        const expired = `if redis.call('get',KEYS[1])~=ARGV[1] then return 0 end;
          redis.call('del',KEYS[2]); redis.call('zrem',KEYS[3],ARGV[2]); redis.call('publish',ARGV[3],ARGV[2]); return 1`;
        await this.redis.eval(expired,3,lockKey,this.key(code),`${this.prefix}rooms`,lockToken,code,this.channel);
        return { room: null, result: null };
      }
      const result = await operation(room);
      room.version++;
      // Fencing prevents an expired mutex holder from committing stale state.
      // Write, room registry and notification are one atomic Redis transaction.
      const lua = `if redis.call('get',KEYS[1])~=ARGV[1] then return 0 end;
        if ARGV[2]=='delete' then redis.call('del',KEYS[2]); redis.call('zrem',KEYS[3],ARGV[5]);
        else redis.call('set',KEYS[2],ARGV[2],'PX',ARGV[3]); redis.call('zadd',KEYS[3],ARGV[4],ARGV[5]); end;
        if ARGV[6]=='yes' then redis.call('publish',ARGV[7],ARGV[5]); end; return 1`;
      const committed = await this.redis.eval(lua,3,lockKey,this.key(code),`${this.prefix}rooms`,lockToken,
        room.players.length ? JSON.stringify(room) : 'delete',ROOM_TTL_MS,room.activity,code,
        publish || result?.changed ? 'yes' : 'no',this.channel);
      if (committed !== 1) throw new Error('Le salon a changé pendant l’action. Réessayez.');
      return { room, result };
    });
  }
  async close() { this.redis.disconnect(); }
}
