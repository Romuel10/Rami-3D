import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { Buffer } from 'node:buffer';
import { createGame, applyAction, forfeitPlayer, matchResult, nextRound, viewFor } from './engine.mjs';
import { validVoiceFrame } from './voice.mjs';

class ClientError extends Error { constructor(message, fatal = false) { super(message); this.fatal = fatal; } }
const cleanText = (value, length) => typeof value === 'string' ? Array.from(value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim()).slice(0, length).join('') : '';
const PROVINCES = ['Antananarivo', 'Antsiranana', 'Fianarantsoa', 'Mahajanga', 'Toamasina', 'Toliara'];
const STAKES = [0, 25, 50, 100, 200, 500];
const secretEquals = (a, b) => typeof a === 'string' && typeof b === 'string' && /^[0-9a-f]{48}$/.test(a) && /^[0-9a-f]{48}$/.test(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const currentDuel = room => room.tournament?.duels[room.tournament.stage];
const gameSeat = (room, index) => currentDuel(room)?.seats.indexOf(index) ?? index;
const matchFinished = room => !!room.game && matchResult(room.game).finished;
const finished = room => room.started && (room.tournament ? room.tournament.champion !== null : matchFinished(room));
const forfeited = (room, index) => !!room.game?.players[gameSeat(room, index)]?.forfeited;
const active = (room, index) => !room.players[index].departed && !forfeited(room, index);
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
    if (fatal) {
      entry.leaving = true;
      // Godot polls the socket once per frame. Give it time to read the reason.
      setTimeout(() => entry.socket.close(1008, 'Salon inaccessible'), 200).unref?.();
    }
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
      if (room.started && !player.connection && !player.departed && player.deadline > 0 && player.deadline <= now) {
        this.abandon(room, i, 'déconnexion prolongée');
        changed = true;
      }
    }
    return this.maybeRematch(room) || changed;
  }
  beginMatch(room) {
    room.started = true;
    for (const p of room.players) { p.rematch_ready = false; p.departed = false; }
    if (room.tournament) this.beginDuel(room, 0);
    else room.game = createGame(room.players.map(p => p.name), { triCards: room.tri_cards, rounds: room.rounds ?? 1 });
  }
  beginDuel(room, stage) {
    const tournament = room.tournament;
    const seats = stage === 2 ? tournament.duels.slice(0, 2).map(duel => duel.winner).filter(i => Number.isInteger(i) && i >= 0) : tournament.duels[stage].seats;
    const available = seats.filter(i => !room.players[i].departed);
    if (available.some(i => !room.players[i].connection)) throw new ClientError('Attendez la reconnexion des joueurs de ce duel.');
    tournament.stage = stage;
    const duel = tournament.duels[stage];
    duel.seats = seats;
    if (available.length < 2) {
      duel.winner = available[0] ?? -1;
      room.game = null;
      if (stage === 2) tournament.champion = duel.winner;
    } else room.game = createGame(seats.map(i => room.players[i].name), { triCards: room.tri_cards, rounds: room.rounds });
  }
  settleDuel(room) {
    const duel = currentDuel(room);
    if (!duel || duel.winner !== null || !matchFinished(room)) return;
    const winners = matchResult(room.game).winners;
    // In a tied two-player series, the odd number of rounds breaks the tie.
    const wins = room.game.match.results.reduce((total, round) => total + (round.winner === 0 ? 1 : -1), 0);
    duel.winner = duel.seats[winners.length === 1 ? winners[0] : (wins > 0 ? 0 : 1)];
    if (room.tournament.stage === 2) room.tournament.champion = duel.winner;
  }
  advanceRound(room) {
    const result = nextRound(room.game);
    if (!result.ok) throw new ClientError(result.error);
    room.players.forEach((p, i) => {
      const seat = gameSeat(room, i);
      if (p.departed && seat >= 0 && !forfeited(room, i) && room.game.winner < 0) forfeitPlayer(room.game, seat, 'abandon');
    });
    this.settleDuel(room);
  }
  abandon(room, index, reason) {
    const player = room.players[index];
    const seat = gameSeat(room, index);
    player.connection = ''; player.deadline = 0; player.departed = true;
    if (seat < 0 || !room.game || matchFinished(room) || forfeited(room, index)) return;
    if (room.game.winner < 0) forfeitPlayer(room.game, seat, reason);
    else if (room.players.filter((_p, i) => gameSeat(room, i) >= 0 && active(room, i)).length === 1) this.advanceRound(room);
    this.settleDuel(room);
  }
  maybeRematch(room) {
    if (room.tournament || !finished(room)) return false;
    const remaining = room.players.filter((_p, i) => active(room, i));
    if (!remaining.length || !remaining.every(p => p.rematch_ready)) return false;
    room.players = remaining;
    room.game = null; room.started = false;
    if (room.stake) {
      // Voting for a rematch accepts the same stake. The host starts it from
      // the lobby so a failed debit can be shown without losing the votes.
      for (const p of remaining) { p.stake_ready = true; p.rematch_ready = false; }
    } else if (remaining.length >= 2 && (!room.player_count || remaining.length === capacity(room)) && remaining.every(p => p.connection)) this.beginMatch(room);
    else for (const p of remaining) p.rematch_ready = false;
    return true;
  }
  waiting(room) { return room.players.filter((p, i) => gameSeat(room, i) >= 0 && active(room, i) && !p.connection); }
  paused(room) { return !!room.game && room.game.winner < 0 && this.waiting(room).length > 0; }
  remaining(room) {
    if (!this.paused(room)) return 0;
    return Math.max(0, Math.min(this.graceMs, ...this.waiting(room).map(p => p.deadline - Date.now())));
  }
  async transact(code, operation, publish = true) {
    return this.store.update(code, async room => {
      const changed = this.expire(room);
      try { return { changed, value: await operation(room) }; }
      catch (error) {
        if (error instanceof ClientError) return { changed, error };
        throw error;
      } finally {
        if (room.stake && room.game && !room.game.stake_result && matchFinished(room)) {
          const winners = matchResult(room.game).winners;
          room.game.stake_result = { winner: winners.length === 1 ? winners[0] : null };
        }
        if (room.started && room.players.every((_p, i) => !active(room, i))) room.players = [];
      }
    }, { publish });
  }
  seatFor(entry, room) {
    const index = room.players.findIndex(p => p.connection === entry.id && secretEquals(p.token, entry.token));
    if (index < 0) throw new ClientError('Cette connexion a été remplacée. Reconnectez-vous.', true);
    return index;
  }
  async message(entry, message) {
    if (entry.leaving) return;
    try {
      if (!entry.code) {
        if (message.type === 'create') return await this.create(entry, message);
        if (message.type === 'join') return await this.join(entry, message);
        if (message.type === 'wallet_sync') return await this.syncWallet(entry, message);
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
            this.abandon(room, index, 'abandon');
            this.maybeRematch(room);
          } else room.players.splice(index, 1);
          return 'left';
        }
        if (message.type === 'start') {
          if (index !== owner(room)) throw new ClientError('Seul l’hôte peut lancer la partie.');
          if (room.started) throw new ClientError('La partie a déjà commencé.');
          if (room.players.length < 2) throw new ClientError('Il faut au moins deux joueurs.');
          if (room.player_count && room.players.length !== capacity(room)) throw new ClientError(`Attendez les ${capacity(room)} joueurs prévus.`);
          if (room.players.some(p => !p.connection)) throw new ClientError('Attendez la reconnexion de tous les joueurs.');
          if (room.stake && room.players.some(p => !p.stake_ready)) throw new ClientError('Chaque joueur doit accepter la mise.');
          this.beginMatch(room);
          return;
        }
        if (message.type === 'accept_stake') {
          if (room.started || !room.stake || message.stake !== room.stake) throw new ClientError('Cette mise n’est plus disponible.');
          player.stake_ready = true;
          return;
        }
        if (message.type === 'configure') {
          if (room.started || index !== owner(room)) throw new ClientError('Seul l’hôte peut régler un salon en attente.');
          if (room.tournament) throw new ClientError('Le tournoi réunit quatre joueurs.');
          const count = message.player_count;
          if (!Number.isInteger(count) || ![2,3,4].includes(count)) throw new ClientError('Choisissez 2, 3 ou 4 joueurs.');
          if (count < room.players.length) throw new ClientError('Des joueurs sont déjà présents : ce nombre est trop petit.');
          room.player_count = count;
          return;
        }
        if (message.type === 'kick') {
          if (room.started || index !== owner(room)) throw new ClientError('Seul l’hôte peut retirer un invité du salon en attente.');
          const target = room.players.findIndex(p => p.seat_id && p.seat_id === message.seat_id);
          if (target < 0 || target === index) throw new ClientError('Cet invité n’est plus dans le salon.');
          const [removed] = room.players.splice(target, 1);
          room.removed = [...(room.removed ?? []), removed.connection].slice(-16);
          return;
        }
        if (message.type === 'next_round') {
          if (index !== owner(room)) throw new ClientError('Seul l’hôte peut lancer la manche suivante.');
          if (!room.game || message.session_id !== room.game.session_id || message.round !== room.game.match.round) throw new ClientError('Cette manche a déjà changé.');
          if (this.waiting(room).length) throw new ClientError('Attendez la reconnexion des joueurs.');
          this.advanceRound(room);
          return;
        }
        if (message.type === 'advance_tournament') {
          const duel = currentDuel(room);
          if (index !== owner(room)) throw new ClientError('Seul l’hôte peut lancer le prochain duel.');
          if (!duel || duel.winner === null || finished(room) || message.stage !== room.tournament.stage) throw new ClientError('Le prochain duel n’est pas disponible.');
          this.beginDuel(room, room.tournament.stage + 1);
          return;
        }
        if (message.type === 'rematch') {
          if (room.tournament || !finished(room)) throw new ClientError('Attendez la fin du match pour rejouer.');
          if (forfeited(room, index) || player.departed) throw new ClientError('Cette place a quitté le match.', true);
          // A delayed duplicate vote must not apply to a later match.
          if (message.session_id !== room.game.session_id) throw new ClientError('Ce résultat appartient au match précédent.');
          player.rematch_ready = true;
          this.maybeRematch(room);
          return;
        }
        if (message.type === 'action') {
          const seat = gameSeat(room, index);
          if (!room.started) throw new ClientError('La partie n’a pas encore commencé.');
          if (!room.game || seat < 0) throw new ClientError('Attendez votre prochain duel.');
          if (forfeited(room, index)) throw new ClientError('Vous avez abandonné cette partie.', true);
          if (this.paused(room)) throw new ClientError('La partie attend la reconnexion d’un joueur.');
          if ((message.session_id || room.stake || room.tournament || (room.rounds ?? 1) > 1) && message.session_id !== room.game.session_id) throw new ClientError('Cette action appartient au match précédent.');
          if ((room.rounds ?? 1) > 1 && message.round !== room.game.match.round) throw new ClientError('Cette action appartient à une autre manche.');
          if (!message.action || typeof message.action !== 'object' || Array.isArray(message.action)) throw new ClientError('Action incorrecte.');
          if (Date.now() - entry.lastAction < 40) throw new ClientError('Attendez un instant avant votre prochaine action.');
          entry.lastAction = Date.now();
          const actionResult = applyAction(room.game, seat, message.action);
          if (!actionResult.ok) throw new ClientError(actionResult.error);
          this.settleDuel(room);
          return;
        }
        throw new ClientError('Message inconnu.');
      });
      if (!result.room) throw new ClientError('Le salon a expiré.', true);
      if (result.result?.error) throw result.result.error;
      if (result.result?.value === 'left') {
        entry.leaving = true;
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
      else if (error.code === 'RM001') this.error(entry, 'Un joueur n’a plus assez de Kirobo pour la mise.');
      else throw error;
    }
  }
  walletDigest(key) {
    if (!this.store.syncWallet || typeof key !== 'string' || !/^[0-9a-f]{48}$/.test(key)) {
      throw new ClientError('Ce salon nécessite un portefeuille Kirobo. Mettez le jeu à jour.', true);
    }
    return createHash('sha256').update(key).digest('hex');
  }
  async syncWallet(entry, message) {
    const key = this.walletDigest(message.wallet_key);
    const wins = message.wins;
    if (!Array.isArray(wins) || wins.length > 24 || wins.some(win =>
      typeof win?.id !== 'string' || !/^[0-9a-f]{2,16}$/.test(win.id) || ![0, 1, 2].includes(win.level))) {
      throw new ClientError('Reçus de victoire invalides.', true);
    }
    const balance = await this.store.syncWallet(key, wins.map(({ id, level }) => ({ id, level })));
    this.send(entry, { type: 'wallet', balance });
    entry.leaving = true;
    // Let the client consume the response before closing. The auth deadline
    // still closes this one-shot connection if the client stops polling.
  }
  async stakeWallet(secret, stake) {
    const key = this.walletDigest(secret);
    if (await this.store.syncWallet(key, []) < stake) throw new ClientError('Votre solde est insuffisant pour cette mise.', true);
    return key;
  }
  connectedPlayer(entry, message, token) {
    return {
      name: cleanText(message.name, 20) || 'Joueur', province: PROVINCES.includes(message.province) ? message.province : '',
      seat_id: randomUUID(), token, connection: entry.id, leaseUntil: Date.now() + this.leaseMs, deadline: 0,
    };
  }
  async create(entry, message) {
    const tri = message.tri_cards ?? 0;
    if (!Number.isInteger(tri) || ![0, 6, 12].includes(tri)) throw new ClientError('Choisissez 6 ou 12 cartes pour le Tri.', true);
    const token = randomBytes(24).toString('hex');
    const count = message.player_count ?? 0; // Legacy rooms keep their original default capacity.
    if (!Number.isInteger(count) || ![0,2,3,4].includes(count)) throw new ClientError('Nombre de joueurs incorrect.', true);
    const rounds = message.rounds ?? 1;
    if (![1, 3, 5].includes(rounds)) throw new ClientError('Choisissez 1, 3 ou 5 manches.', true);
    const tournament = message.tournament === true ? {
      name: cleanText(message.tournament_name, 36) || 'Tournoi entre amis', stage: -1, champion: null,
      duels: [{ seats: [0, 1], winner: null }, { seats: [2, 3], winner: null }, { seats: [], winner: null }],
    } : null;
    const stake = message.stake ?? 0;
    if (!STAKES.includes(stake) || (stake > 0 && (tournament || !count))) throw new ClientError('Mise de salon incorrecte.', true);
    const player = this.connectedPlayer(entry, message, token);
    if (stake) Object.assign(player, { wallet: await this.stakeWallet(message.wallet_key, stake), stake_ready: true });
    const room = await this.store.create({ players: [player], tri_cards: tri, player_count: tournament ? 4 : count, rounds, tournament, stake, voice_topic: randomBytes(24).toString('hex'), started: false, game: null });
    this.authenticate(entry, room, 0, token);
    await this.deliver(room.code);
  }
  async join(entry, message) {
    const code = String(message.code || '');
    if (!/^\d{6}$/.test(code)) throw new ClientError('Le code du salon est incorrect.', true);
    const token = typeof message.token === 'string' ? message.token : '';
    const result = await this.transact(code, async room => {
      let index;
      let assigned = token;
      if (token) {
        index = room.players.findIndex(p => secretEquals(p.token, token));
        if (index < 0) throw new ClientError('Le jeton de reconnexion est incorrect.', true);
        if (forfeited(room, index) || room.players[index].departed) throw new ClientError('Cette place a été perdue par abandon.', true);
        // A valid private bearer may take over its own connection. This permits
        // immediate recovery when a previous Function vanished without close.
        Object.assign(room.players[index], { connection: entry.id, leaseUntil: Date.now() + this.leaseMs, deadline: 0 });
      } else {
        if (room.started) throw new ClientError('Cette partie a déjà commencé.', true);
        if (room.players.length >= capacity(room)) throw new ClientError('Le salon est complet.', true);
        if ((room.tournament || (room.rounds ?? 1) > 1) && message.series !== true) throw new ClientError('Mettez le jeu à jour pour rejoindre ce salon.', true);
        assigned = randomBytes(24).toString('hex');
        index = room.players.length;
        const player = this.connectedPlayer(entry, message, assigned);
        if (room.stake) {
          player.wallet = await this.stakeWallet(message.wallet_key, room.stake);
          if (room.players.some(p => p.wallet === player.wallet)) throw new ClientError('Ce portefeuille occupe déjà une place dans ce salon.', true);
          player.stake_ready = false;
        }
        room.players.push(player);
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
    this.send(entry, { type: 'welcome', player: index, token: entry.token, code: room.code, is_host: index === owner(room), features: { rematch: true, player_count: true, series: true, kick: true, voice: !!this.voice } });
  }
  sendState(entry, room, index) {
    const seat = gameSeat(room, index);
    if (!room.game || seat < 0) return;
    const view = viewFor(room.game, seat);
    const seats = currentDuel(room)?.seats ?? room.players.map((_p, i) => i);
    view.players.forEach((player, i) => { player.province = room.players[seats[i]].province ?? ''; });
    const duel = currentDuel(room);
    if (room.stake) {
      view.stake = room.stake;
      const result = room.game.stake_result;
      if (result) view.stake_net = result.winner === null ? 0 : (result.winner === seat ? room.players.length - 1 : -1) * room.stake;
    }
    if (Number.isInteger(duel?.winner) && duel.winner >= 0) {
      if (view.match_result.winners.length > 1) view.match_result.tie_break = true;
      view.match_result.winners = [duel.seats.indexOf(duel.winner)];
    }
    this.send(entry, { type: 'state', data: { ...view, paused: this.paused(room), reconnect_remaining_ms: this.remaining(room), your_index: seat, online: true } });
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
        if (index < 0) {
          this.error(entry, room.removed?.includes(entry.id) ? 'L’hôte vous a retiré du salon.' : 'Cette connexion a été remplacée. Reconnectez-vous.', true);
          continue;
        }
        if (entry.version >= room.version) continue;
        if (entry.index !== index) {
          entry.index = index;
          this.welcome(entry, room, index);
        }
        const players = room.players.map((p, i) => ({ name: p.name, province: p.province ?? '', seat_id: p.seat_id ?? '', connected: !!p.connection && !p.departed, forfeited: forfeited(room, i), rematch_ready: !!p.rematch_ready, departed: !!p.departed, stake_ready: !!p.stake_ready }));
        const playing = !!room.game && gameSeat(room, index) >= 0;
        const progress = room.tournament && room.game ? { round: room.game.match.round, round_finished: room.game.winner >= 0, finished: matchFinished(room), session_id: room.game.session_id } : null;
        const data = { code, players, port: 443, started: room.started, tri_cards: room.tri_cards, player_count: room.player_count || 0, capacity: capacity(room), finished: finished(room), host: index === owner(room), your_index: index, rounds: room.rounds ?? 1, stake: room.stake ?? 0, tournament: room.tournament ?? null, progress, playing };
        const lobbyKey = JSON.stringify(data);
        if (lobbyKey !== entry.lobbyKey) this.send(entry, { type: 'lobby', data });
        entry.lobbyKey = lobbyKey;
        const stateKey = playing ? JSON.stringify([room.game.session_id, room.game.revision, this.paused(room), gameSeat(room, index)]) : '';
        if (playing && stateKey !== entry.stateKey) this.sendState(entry, room, index);
        entry.stateKey = stateKey;
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
