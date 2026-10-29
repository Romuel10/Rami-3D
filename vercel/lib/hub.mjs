import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { createGame, applyAction, forfeitPlayer, viewFor } from './engine.mjs';

class ClientError extends Error { constructor(message, fatal = false) { super(message); this.fatal = fatal; } }
const cleanName = value => String(value || 'Joueur').replace(/[\n\r\t]/g, ' ').trim().slice(0, 20) || 'Joueur';
const secretEquals = (a, b) => typeof a === 'string' && typeof b === 'string' && /^[0-9a-f]{48}$/.test(a) && /^[0-9a-f]{48}$/.test(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const finished = room => room.started && room.game?.winner >= 0;
const forfeited = (room, index) => room.started && !!room.game?.players[index]?.forfeited;
const owner = room => Math.max(0, room.players.findIndex((_, i) => !forfeited(room, i)));

export class GameHub {
  constructor(store, { graceMs = 60000, leaseMs = 15000, heartbeatMs = 5000, sweepMs = 1000, authMs = 8000 } = {}) {
    this.store = store;
    this.graceMs = graceMs;
    this.leaseMs = leaseMs;
    this.heartbeatMs = heartbeatMs;
    this.sweepMs = sweepMs;
    this.authMs = authMs;
    this.entries = new Set();
    this.closed = false;
    this.pending = new Set();
    this.delivery = new Map();
  }
  async start() {
    await this.store.ready();
    this.subscriber = this.store.redis.duplicate({ lazyConnect: true });
    this.subscriber.on('error', () => {});
    this.subscriber.on('ready', () => {
      // Redis Pub/Sub is at-most-once: reload after any subscriber reconnect.
      for (const code of new Set([...this.entries].map(entry => entry.code).filter(Boolean))) this.track(this.deliver(code));
    });
    await this.subscriber.connect();
    this.subscriber.on('message', (_channel, code) => this.track(this.deliver(code)));
    await this.subscriber.subscribe(this.store.channel);
    this.timer = setInterval(() => this.track(this.tick()), this.sweepMs);
    this.timer.unref?.();
  }
  track(promise) {
    this.pending.add(promise);
    promise.catch(() => {}).finally(() => this.pending.delete(promise));
    return promise;
  }
  attach(socket) {
    const entry = { socket, id: randomUUID(), code: '', token: '', index: -1, version: -1, lastAction: 0, lastBeat: 0, alive: true, packetStart: Date.now(), packetCount: 0 };
    this.entries.add(entry);
    entry.authTimer = setTimeout(() => { if (!entry.code) socket.close(1008, 'Authentification requise'); }, this.authMs);
    entry.authTimer.unref?.();
    entry.chain = Promise.resolve();
    socket.on('message', (data, binary) => {
      if (this.closed || entry.leaving) return;
      if (binary) { socket.close(1003, 'JSON texte requis'); return; }
      if (Date.now() - entry.packetStart > 1000) { entry.packetStart = Date.now(); entry.packetCount = 0; }
      if (++entry.packetCount > 30) { socket.close(1008, 'Trop de messages'); return; }
      let message;
      try { message = JSON.parse(data.toString()); } catch { socket.close(1007, 'JSON incorrect'); return; }
      if (!message || typeof message !== 'object' || Array.isArray(message)) { socket.close(1007, 'Objet JSON requis'); return; }
      entry.chain = entry.chain.then(() => this.message(entry, message)).catch(() => this.error(entry, 'Le serveur est momentanément indisponible. Réessayez.', false));
      this.track(entry.chain);
    });
    socket.on('pong', () => { entry.alive = true; });
    socket.on('error', () => {});
    socket.on('close', () => {
      clearTimeout(entry.authTimer);
      this.entries.delete(entry);
      this.track(entry.chain.then(() => this.disconnect(entry)));
    });
  }
  send(entry, value) {
    if (entry.socket.readyState !== 1) return;
    if (entry.socket.bufferedAmount > 262144) { entry.socket.close(1013, 'Connexion trop lente'); return; }
    entry.socket.send(JSON.stringify(value));
  }
  error(entry, message, fatal = false) {
    this.send(entry, { type: 'error', message, fatal });
    if (fatal) { entry.leaving = true; entry.socket.close(1008, 'Salon inaccessible'); }
  }
  expire(room) {
    const now = Date.now();
    let changed = false;
    for (let i = room.players.length - 1; i >= 0; i--) {
      const player = room.players[i];
      if (player.connection && player.leaseUntil <= now) {
        player.connection = '';
        player.deadline = player.leaseUntil + this.graceMs;
        changed = true;
      }
      if (!room.started && !player.connection) { room.players.splice(i, 1); changed = true; }
    }
    if (room.started && !finished(room)) {
      for (let i = 0; i < room.players.length; i++) {
        const player = room.players[i];
        if (!player.connection && !forfeited(room, i) && player.deadline > 0 && player.deadline <= now) {
          if (forfeitPlayer(room.game, i, 'déconnexion prolongée').ok) { player.deadline = 0; changed = true; }
        }
      }
    }
    return changed;
  }
  paused(room) { return room.started && !finished(room) && room.players.some((p, i) => !p.connection && !forfeited(room, i)); }
  remaining(room) {
    if (!this.paused(room)) return 0;
    return Math.max(0, Math.min(this.graceMs, ...room.players.filter((p, i) => !p.connection && !forfeited(room, i)).map(p => p.deadline - Date.now())));
  }
  async transact(code, operation, publish = true) {
    return this.store.update(code, room => {
      const changed = this.expire(room);
      try { return { changed, value: operation(room) }; }
      catch (error) {
        if (error instanceof ClientError) return { changed, error };
        throw error;
      }
    }, { publish });
  }
  seatFor(entry, room) {
    const index = room.players.findIndex(p => p.connection === entry.id && secretEquals(p.token, entry.token));
    if (index < 0) throw new ClientError('Cette connexion a été remplacée. Reconnectez-vous.', true);
    return index;
  }
  async message(entry, message) {
    try {
      if (!entry.code) {
        if (message.type === 'create') return await this.create(entry, message);
        if (message.type === 'join') return await this.join(entry, message);
        throw new ClientError('Créez ou rejoignez d’abord un salon.');
      }
      const result = await this.transact(entry.code, room => {
        const index = this.seatFor(entry, room);
        room.activity = Date.now();
        const player = room.players[index];
        player.leaseUntil = Date.now() + this.leaseMs;
        if (message.type === 'leave') {
          if (room.started) {
            if (!finished(room) && !forfeited(room, index)) forfeitPlayer(room.game, index, 'abandon');
            player.connection = ''; player.deadline = 0;
          } else room.players.splice(index, 1);
          entry.leaving = true;
          return 'left';
        }
        if (message.type === 'start') {
          if (index !== owner(room)) throw new ClientError('Seul l’hôte peut lancer la partie.');
          if (room.started) throw new ClientError('La partie a déjà commencé.');
          if (room.players.length < 2) throw new ClientError('Il faut au moins deux joueurs.');
          room.game = createGame(room.players.map(p => p.name), { triCards: room.tri_cards });
          room.started = true;
          return;
        }
        if (message.type === 'action') {
          if (!room.started) throw new ClientError('La partie n’a pas encore commencé.');
          if (forfeited(room, index)) throw new ClientError('Vous avez abandonné cette partie.', true);
          if (this.paused(room)) throw new ClientError('La partie attend la reconnexion d’un joueur.');
          if (!message.action || typeof message.action !== 'object' || Array.isArray(message.action)) throw new ClientError('Action incorrecte.');
          if (Date.now() - entry.lastAction < 40) throw new ClientError('Attendez un instant avant votre prochaine action.');
          entry.lastAction = Date.now();
          const actionResult = applyAction(room.game, index, message.action);
          if (!actionResult.ok) throw new ClientError(actionResult.error);
          return;
        }
        throw new ClientError('Message inconnu.');
      });
      if (!result.room) throw new ClientError('Le salon a expiré.', true);
      if (result.result?.error) throw result.result.error;
      if (result.result?.value === 'left') {
        // This result goes only to the departing owner, before closing. The
        // broadcast reads the committed room separately for each remaining seat.
        if (result.room.started) this.sendState(entry, result.room, entry.index);
        entry.code = ''; entry.token = ''; entry.index = -1;
        entry.socket.close(1000, 'Départ du salon');
      }
      await this.deliver(result.room.code);
    } catch (error) {
      if (error instanceof ClientError) this.error(entry, error.message, error.fatal);
      else throw error;
    }
  }
  connectedPlayer(entry, name, token) { return { name: cleanName(name), token, connection: entry.id, leaseUntil: Date.now() + this.leaseMs, deadline: 0 }; }
  async create(entry, message) {
    const tri = message.tri_cards ?? 0;
    if (!Number.isInteger(tri) || ![0, 6, 12].includes(tri)) throw new ClientError('Choisissez 6 ou 12 cartes pour le Tri.', true);
    const token = randomBytes(24).toString('hex');
    const room = await this.store.create({ players: [this.connectedPlayer(entry, message.name, token)], tri_cards: tri, started: false, game: null });
    this.authenticate(entry, room, 0, token);
    await this.deliver(room.code);
  }
  async join(entry, message) {
    const code = String(message.code || '');
    if (!/^\d{6}$/.test(code)) throw new ClientError('Le code du salon est incorrect.', true);
    const token = typeof message.token === 'string' ? message.token : '';
    const result = await this.transact(code, room => {
      let index;
      let assigned = token;
      if (token) {
        index = room.players.findIndex(p => secretEquals(p.token, token));
        if (index < 0) throw new ClientError('Le jeton de reconnexion est incorrect.', true);
        if (forfeited(room, index)) throw new ClientError('Cette place a été perdue par abandon.', true);
        // A valid private bearer may take over its own connection. This permits
        // immediate recovery when a previous Function vanished without close.
        room.players[index] = this.connectedPlayer(entry, room.players[index].name, token);
      } else {
        if (room.started) throw new ClientError('Cette partie a déjà commencé.', true);
        if (room.players.length >= (room.tri_cards ? 2 : 4)) throw new ClientError('Le salon est complet.', true);
        assigned = randomBytes(24).toString('hex');
        index = room.players.length;
        room.players.push(this.connectedPlayer(entry, message.name, assigned));
      }
      room.activity = Date.now();
      return { index, token: assigned };
    });
    if (!result.room) throw new ClientError('Le code du salon est incorrect.', true);
    if (result.result?.error) throw result.result.error;
    const { index, token: assigned } = result.result.value;
    this.authenticate(entry, result.room, index, assigned);
    await this.deliver(code);
  }
  authenticate(entry, room, index, token) {
    clearTimeout(entry.authTimer);
    entry.code = room.code; entry.index = index; entry.token = token;
    this.send(entry, { type: 'welcome', player: index, token, code: room.code, is_host: index === owner(room) });
  }
  sendState(entry, room, index) {
    const view = viewFor(room.game, index);
    this.send(entry, { type: 'state', data: { ...view, paused: this.paused(room), reconnect_remaining_ms: this.remaining(room), your_index: index, online: true } });
  }
  async deliver(code) {
    // Serialize fan-out per room so a slow Redis read cannot send an older
    // revision after a newer one. Subscribers carry only room codes, no cards.
    const previous = this.delivery.get(code) || Promise.resolve();
    const task = previous.catch(() => {}).then(async () => {
      const room = await this.store.read(code);
      for (const entry of this.entries) {
        if (entry.code !== code || entry.leaving) continue;
        if (!room) { this.error(entry, 'Le salon a expiré.', true); continue; }
        const index = room.players.findIndex(p => p.connection === entry.id && secretEquals(p.token, entry.token));
        if (index < 0) { this.error(entry, 'Cette connexion a été remplacée. Reconnectez-vous.', true); continue; }
        if (entry.version >= room.version) continue;
        if (entry.index !== index) {
          entry.index = index;
          this.send(entry, { type: 'welcome', player: index, token: entry.token, code, is_host: index === owner(room) });
        }
        const players = room.players.map((p, i) => ({ name: p.name, connected: !!p.connection, forfeited: forfeited(room, i) }));
        this.send(entry, { type: 'lobby', data: { code, players, port: 443, started: room.started, tri_cards: room.tri_cards, host: index === owner(room), your_index: index } });
        if (room.started) this.sendState(entry, room, index);
        entry.version = room.version;
      }
    });
    this.delivery.set(code, task);
    try { await task; } finally { if (this.delivery.get(code) === task) this.delivery.delete(code); }
  }
  async disconnect(entry) {
    if (!entry.code || entry.leaving) return;
    const code = entry.code;
    await this.transact(code, room => {
      const index = room.players.findIndex(p => p.connection === entry.id && secretEquals(p.token, entry.token));
      if (index < 0) return;
      if (!room.started) room.players.splice(index, 1);
      else {
        const player = room.players[index];
        player.connection = '';
        player.deadline = !finished(room) && !forfeited(room, index) ? Date.now() + this.graceMs : 0;
      }
    });
    await this.deliver(code);
  }
  async tick() {
    if (this.closed || this.tickRunning) return;
    this.tickRunning = true;
    try {
      const now = Date.now();
      const codes = new Set();
      for (const entry of this.entries) {
        if (!entry.code || entry.leaving) continue;
        codes.add(entry.code);
        if (now - entry.lastBeat < this.heartbeatMs) continue;
        if (!entry.alive) { entry.socket.terminate(); continue; }
        entry.alive = false; entry.socket.ping(); entry.lastBeat = now;
        await this.transact(entry.code, room => {
          const index = room.players.findIndex(p => p.connection === entry.id && secretEquals(p.token, entry.token));
          if (index >= 0) room.players[index].leaseUntil = Date.now() + this.leaseMs;
        }, false);
      }
      for (const code of codes) {
        const room = await this.store.read(code);
        if(!room) { await this.deliver(code); continue; }
        const expires = room.players.some((player,index) =>
          (player.connection && player.leaseUntil <= now) ||
          (!player.connection && !room.started) ||
          (!player.connection && room.started && !finished(room) && !forfeited(room,index) && player.deadline > 0 && player.deadline <= now));
        if(expires) await this.transact(code, () => {}, false);
      }
    } finally { this.tickRunning = false; }
  }
  async close({ abrupt = false } = {}) {
    this.closed = true;
    clearInterval(this.timer);
    for (const entry of this.entries) {
      clearTimeout(entry.authTimer);
      if (abrupt) { entry.leaving = true; entry.socket.terminate(); }
      else entry.socket.close(1001, 'Redémarrage du serveur');
    }
    await Promise.allSettled([...this.pending]);
    this.subscriber?.disconnect();
    await this.store.close();
  }
}
