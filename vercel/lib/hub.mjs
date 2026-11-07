import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { createGame, applyAction, forfeitPlayer, viewFor } from './engine.mjs';
import { validVoiceFrame } from './voice.mjs';

class ClientError extends Error { constructor(message, fatal = false) { super(message); this.fatal = fatal; } }
const cleanName = value => String(value || 'Joueur').replace(/[\n\r\t]/g, ' ').trim().slice(0, 20) || 'Joueur';
const secretEquals = (a, b) => typeof a === 'string' && typeof b === 'string' && /^[0-9a-f]{48}$/.test(a) && /^[0-9a-f]{48}$/.test(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const finished = room => room.started && room.game?.winner >= 0;
const forfeited = (room, index) => room.started && !!room.game?.players[index]?.forfeited;
const owner = room => Math.max(0, room.players.findIndex((p, i) => !p.departed && !forfeited(room, i)));
const capacity = room => room.player_count || (room.tri_cards ? 2 : 4);

export class GameHub {
  constructor(store, { graceMs = 60000, leaseMs = 15000, heartbeatMs = 5000, sweepMs = 1000, authMs = 8000, preserveLobby = false, voice = null } = {}) {
    this.store = store;
    this.graceMs = graceMs;
    this.leaseMs = leaseMs;
    this.heartbeatMs = heartbeatMs;
    this.sweepMs = sweepMs;
    this.authMs = authMs;
    this.preserveLobby = preserveLobby;
    this.entries = new Set();
    this.closed = false;
    this.pending = new Set();
    this.delivery = new Map();
    this.voice = voice;
    this.voiceRooms = new Map();
    this.roomCache = new Map();
  }
  async start() {
    await this.store.ready();
    if (this.store.redis) {
      this.subscriber = this.store.redis.duplicate({ lazyConnect: true });
      this.subscriber.on('error', () => {});
      this.subscriber.on('ready', () => {
        // Redis Pub/Sub is at-most-once: reload after any subscriber reconnect.
        for (const code of new Set([...this.entries].map(entry => entry.code).filter(Boolean))) this.track(this.deliver(code));
      });
      await this.subscriber.connect();
      this.subscriber.on('message', (_channel, code) => this.track(this.deliver(code)));
      await this.subscriber.subscribe(this.store.channel);
    }
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
      // Speech must never accumulate behind a slow database action. Membership
      // is checked against the same fresh, private room cache used for fan-out.
      if (message.type === 'voice') {
        if (entry.code) {
          try { this.sendVoice(entry, message); } catch { /* A stale seat loses voice until reconnect. */ }
        }
        return;
      }
      entry.chain = entry.chain.then(() => this.message(entry, message)).catch(() => this.error(entry, 'Le serveur est momentanément indisponible. Réessayez.', false));
      this.track(entry.chain);
    });
    socket.on('pong', () => { entry.alive = true; });
    socket.on('error', () => {});
    socket.on('close', () => {
      clearTimeout(entry.authTimer);
      this.entries.delete(entry);
      this.track(entry.chain.then(() => this.disconnect(entry)));
      this.releaseVoice(entry.code);
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
      if (!room.started && !player.connection && (!this.preserveLobby || player.deadline <= now)) { room.players.splice(i, 1); changed = true; }
    }
    if (room.started && !finished(room)) {
      for (let i = 0; i < room.players.length; i++) {
        const player = room.players[i];
        if (!player.connection && !forfeited(room, i) && player.deadline > 0 && player.deadline <= now) {
          if (forfeitPlayer(room.game, i, 'déconnexion prolongée').ok) { player.deadline = 0; changed = true; }
        }
      }
    }
    if (finished(room)) {
      for (const player of room.players) {
        if (!player.connection && !player.departed && player.deadline > 0 && player.deadline <= now) {
          player.departed = true; changed = true;
        }
      }
      changed = this.maybeRematch(room) || changed;
    }
    return changed;
  }
  beginMatch(room) {
    room.game = createGame(room.players.map(p => p.name), { triCards: room.tri_cards });
    room.started = true;
    for (const p of room.players) { p.rematch_ready = false; p.departed = false; }
  }
  maybeRematch(room) {
    if (!finished(room)) return false;
    const remaining = room.players.filter((p, i) => !p.departed && !forfeited(room, i));
    if (!remaining.length || !remaining.every(p => p.rematch_ready)) return false;
    room.players = remaining;
    room.game = null; room.started = false;
    if (remaining.length >= 2 && (!room.player_count || remaining.length === capacity(room)) && remaining.every(p => p.connection)) this.beginMatch(room);
    else for (const p of remaining) p.rematch_ready = false;
    return true;
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
      if (message.type === 'voice') return this.sendVoice(entry, message);
      const result = await this.transact(entry.code, room => {
        const index = this.seatFor(entry, room);
        room.activity = Date.now();
        const player = room.players[index];
        player.leaseUntil = Date.now() + this.leaseMs;
        if (message.type === 'leave') {
          if (room.started) {
            if (!finished(room) && !forfeited(room, index)) forfeitPlayer(room.game, index, 'abandon');
            player.connection = ''; player.deadline = 0; player.departed = true;
            this.maybeRematch(room);
          } else room.players.splice(index, 1);
          entry.leaving = true;
          return 'left';
        }
        if (message.type === 'start') {
          if (index !== owner(room)) throw new ClientError('Seul l’hôte peut lancer la partie.');
          if (room.started) throw new ClientError('La partie a déjà commencé.');
          if (room.players.length < 2) throw new ClientError('Il faut au moins deux joueurs.');
          if (room.player_count && room.players.length !== capacity(room)) throw new ClientError(`Attendez les ${capacity(room)} joueurs prévus.`);
          if (room.players.some(p => !p.connection)) throw new ClientError('Attendez la reconnexion de tous les joueurs.');
          this.beginMatch(room);
          return;
        }
        if (message.type === 'configure') {
          if (room.started || index !== owner(room)) throw new ClientError('Seul l’hôte peut régler un salon en attente.');
          const count = message.player_count;
          if (!Number.isInteger(count) || ![2,3,4].includes(count)) throw new ClientError('Choisissez 2, 3 ou 4 joueurs.');
          if (count < room.players.length) throw new ClientError('Des joueurs sont déjà présents : ce nombre est trop petit.');
          room.player_count = count;
          return;
        }
        if (message.type === 'rematch') {
          if (!finished(room)) throw new ClientError('Attendez la fin du match pour rejouer.');
          if (forfeited(room, index) || player.departed) throw new ClientError('Cette place a quitté le match.', true);
          // A delayed duplicate vote must not apply to a later match.
          if (message.session_id !== room.game.session_id) throw new ClientError('Ce résultat appartient au match précédent.');
          player.rematch_ready = true;
          this.maybeRematch(room);
          return;
        }
        if (message.type === 'action') {
          if (!room.started) throw new ClientError('La partie n’a pas encore commencé.');
          if (forfeited(room, index)) throw new ClientError('Vous avez abandonné cette partie.', true);
          if (this.paused(room)) throw new ClientError('La partie attend la reconnexion d’un joueur.');
          if (message.session_id && message.session_id !== room.game.session_id) throw new ClientError('Cette action appartient au match précédent.');
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
        const departing = result.room.players.findIndex(p => secretEquals(p.token, entry.token));
        if (result.room.started && departing >= 0) this.sendState(entry, result.room, departing);
        const oldCode = entry.code;
        entry.code = ''; entry.token = ''; entry.index = -1;
        this.releaseVoice(oldCode);
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
    const count = message.player_count ?? 0; // Legacy rooms keep their original default capacity.
    if (!Number.isInteger(count) || ![0,2,3,4].includes(count)) throw new ClientError('Nombre de joueurs incorrect.', true);
    const room = await this.store.create({ players: [this.connectedPlayer(entry, message.name, token)], tri_cards: tri, player_count: count, voice_topic: randomBytes(24).toString('hex'), started: false, game: null });
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
        if (forfeited(room, index) || room.players[index].departed) throw new ClientError('Cette place a été perdue par abandon.', true);
        // A valid private bearer may take over its own connection. This permits
        // immediate recovery when a previous Function vanished without close.
        room.players[index] = { ...room.players[index], ...this.connectedPlayer(entry, room.players[index].name, token) };
      } else {
        if (room.started) throw new ClientError('Cette partie a déjà commencé.', true);
        if (room.players.length >= capacity(room)) throw new ClientError('Le salon est complet.', true);
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
    this.welcome(entry, room, index);
  }
  welcome(entry, room, index) {
    this.send(entry, { type: 'welcome', player: index, token: entry.token, code: room.code, is_host: index === owner(room), features: { rematch: true, player_count: true, voice: !!this.voice } });
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
      if (room) this.roomCache.set(code, { room, at: Date.now() });
      else this.roomCache.delete(code);
      for (const entry of this.entries) {
        if (entry.code !== code || entry.leaving) continue;
        if (!room) { this.error(entry, 'Le salon a expiré.', true); continue; }
        const index = room.players.findIndex(p => p.connection === entry.id && secretEquals(p.token, entry.token));
        if (index < 0) { this.error(entry, 'Cette connexion a été remplacée. Reconnectez-vous.', true); continue; }
        if (entry.version >= room.version) continue;
        if (entry.index !== index) {
          entry.index = index;
          this.welcome(entry, room, index);
        }
        const players = room.players.map((p, i) => ({ name: p.name, connected: !!p.connection && !p.departed, forfeited: forfeited(room, i), rematch_ready: !!p.rematch_ready, departed: !!p.departed }));
        this.send(entry, { type: 'lobby', data: { code, players, port: 443, started: room.started, tri_cards: room.tri_cards, player_count: room.player_count || 0, capacity: capacity(room), finished: finished(room), host: index === owner(room), your_index: index } });
        if (room.started) this.sendState(entry, room, index);
        entry.version = room.version;
      }
      this.ensureVoice(code, room);
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
      if (!room.started && !this.preserveLobby) room.players.splice(index, 1);
      else {
        const player = room.players[index];
        player.connection = '';
        player.deadline = !forfeited(room, index) && !player.departed ? Date.now() + this.graceMs : 0;
      }
    });
    await this.deliver(code);
  }
  ensureVoice(code, room) {
    if (!this.voice || !room?.voice_topic || ![...this.entries].some(e => e.code === code && !e.leaving)) return;
    let channel = this.voiceRooms.get(code);
    if (channel?.topic !== room.voice_topic) {
      if (channel) this.releaseVoice(code, true);
      this.roomCache.set(code, { room, at: Date.now() });
      channel = { topic: room.voice_topic, ready: false };
      this.voiceRooms.set(code, channel);
      channel.connection = this.voice.subscribe(channel.topic, payload => this.receiveVoice(code, channel, payload), ready => {
        if (this.voiceRooms.get(code) !== channel) return;
        channel.ready = ready;
        for (const e of this.entries) if (e.code === code && !e.leaving) this.send(e, { type: 'voice_status', available: ready });
      });
    }
    for (const e of this.entries) if (e.code === code && !e.leaving && e.voiceAvailable !== channel.ready) {
      e.voiceAvailable = channel.ready;
      this.send(e, { type: 'voice_status', available: channel.ready });
    }
  }
  releaseVoice(code, force = false) {
    if (!force && [...this.entries].some(e => e.code === code && !e.leaving)) return;
    const channel = this.voiceRooms.get(code);
    this.voiceRooms.delete(code);
    this.roomCache.delete(code);
    channel?.connection?.close();
  }
  sendVoice(entry, message) {
    const cached = this.roomCache.get(entry.code);
    const channel = this.voiceRooms.get(entry.code);
    if (!channel?.ready || !cached || Date.now() - cached.at > 4000) return;
    const index = this.seatFor(entry, cached.room);
    if (cached.room.players[index].departed || forfeited(cached.room, index)) return;
    if (!Number.isSafeInteger(message.seq) || message.seq < 0 || message.seq > 2147483647 || message.seq <= (entry.voiceSeq ?? -1) || !validVoiceFrame(message.data)) return;
    const now = Date.now();
    if (now - (entry.voiceAt || 0) < 45) return;
    entry.voiceSeq = message.seq; entry.voiceAt = now;
    channel.connection.send({ sender: entry.id, seq: message.seq, data: message.data, at: now });
  }
  receiveVoice(code, channel, payload) {
    const cached = this.roomCache.get(code);
    if (this.voiceRooms.get(code) !== channel || !cached || Date.now() - cached.at > 4000 || !payload || !validVoiceFrame(payload.data)) return;
    if (!Number.isSafeInteger(payload.seq) || payload.seq < 0 || payload.seq > 2147483647 || !Number.isFinite(payload.at) || Math.abs(Date.now() - payload.at) > 2000) return;
    const index = cached.room.players.findIndex(p => p.connection === payload.sender && !p.departed);
    if (index < 0 || forfeited(cached.room, index)) return;
    for (const e of this.entries) {
      if (e.code !== code || e.leaving || e.id === payload.sender || e.socket.bufferedAmount > 16384) continue;
      if (!cached.room.players.some(p => p.connection === e.id && secretEquals(p.token, e.token) && !p.departed)) continue;
      this.send(e, { type: 'voice', player: index, stream: payload.sender, seq: payload.seq, data: payload.data });
    }
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
        this.roomCache.set(code, { room, at: Date.now() });
        const expires = room.players.some((player,index) =>
          (player.connection && player.leaseUntil <= now) ||
          (!player.connection && !room.started && (!this.preserveLobby || player.deadline <= now)) ||
          (!player.connection && room.started && !player.departed && !forfeited(room,index) && player.deadline > 0 && player.deadline <= now));
        if(expires) await this.transact(code, () => {}, false);
        // Postgres workers poll committed versions instead of Redis Pub/Sub.
        // deliver() still rebuilds a separate private view for each seat.
        if(this.store.pollUpdates) await this.deliver(code);
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
    for (const code of [...this.voiceRooms.keys()]) this.releaseVoice(code, true);
    await this.voice?.close?.();
    await this.store.close();
  }
}
