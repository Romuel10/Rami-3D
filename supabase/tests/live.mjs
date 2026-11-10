/** Black-box checks against an explicitly supplied local or hosted endpoint.
 * Creates QA rooms; no Supabase/admin credential is needed or printed.
 * node supabase/tests/live.mjs wss://PROJECT.supabase.co/functions/v1/rami-online
 * Add --rotation to exercise the hosted worker's 100-second socket rotation.
 */
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
const endpoint = process.argv[2];
if (!endpoint || !/^wss?:\/\//.test(endpoint)) throw new Error('Supply the WebSocket endpoint to test.');
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const clients = [];

class Client {
  constructor() {
    this.socket = new WebSocket(endpoint);
    this.queue = [];
    this.frames = [];
    this.waiters = new Set();
    this.socket.addEventListener('message', event => {
      const frame = JSON.parse(event.data);
      this.frames.push(frame);
      this.queue.push(frame);
      this.flush();
    });
    this.socket.addEventListener('error', () => {});
    clients.push(this);
  }
  async open() {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('WebSocket open timed out')), 15000);
      this.socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
      this.socket.addEventListener('error', () => { clearTimeout(timer); reject(new Error('WebSocket connection failed')); }, { once: true });
    });
    return this;
  }
  send(frame) { this.socket.send(JSON.stringify(frame)); }
  flush() {
    for (const waiter of this.waiters) {
      const i = this.queue.findIndex(frame => frame.type === waiter.type && waiter.predicate(frame));
      if (i < 0) continue;
      this.waiters.delete(waiter);
      clearTimeout(waiter.timer);
      waiter.resolve(this.queue.splice(i, 1)[0]);
    }
  }
  until(type, predicate = () => true) {
    return new Promise((resolve, reject) => {
      const waiter = { type, predicate, resolve };
      waiter.timer = setTimeout(() => {
        this.waiters.delete(waiter);
        reject(new Error(`No ${type} response; received types: ${this.frames.map(f => f.type).join(', ')}; errors: ${this.frames.filter(f => f.type === 'error').map(f => f.message).join('; ')}`));
      }, 15000);
      this.waiters.add(waiter);
      this.flush();
    });
  }
  close() { if (this.socket.readyState < 2) this.socket.close(1000, 'QA reconnect'); }
  leave() { if (this.socket.readyState === 1) this.send({ type: 'leave' }); }
}

async function create(size) {
  const client = await new Client().open();
  client.send({ type: 'create', name: 'QA Supabase Alice', tri_cards: size });
  const welcome = await client.until('welcome');
  await client.until('lobby');
  return { client, welcome };
}
async function join(code, token = '') {
  const client = await new Client().open();
  client.send({ type: 'join', name: 'QA Supabase Bob', code, token });
  const welcome = await client.until('welcome');
  await client.until('lobby');
  return { client, welcome };
}

async function wallet(key, wins = []) {
  const client = await new Client().open();
  client.send({ type: 'wallet_sync', wallet_key: key, wins });
  const response = await client.until('wallet');
  await delay(100);
  assert.equal(client.socket.readyState, WebSocket.OPEN, 'the client closes after reading its wallet acknowledgement');
  client.close();
  return response.balance;
}

async function testStakes() {
  const keys = Array.from({ length: 3 }, () => randomBytes(24).toString('hex'));
  const wins = [{ id: 'a1', level: 0 }, { id: 'a2', level: 1 }, { id: 'a3', level: 2 }];
  assert.equal(await wallet(keys[0], wins), 705);
  assert.equal(await wallet(keys[0], wins), 705, 'replayed offline victories do not duplicate credit');
  const host = await new Client().open();
  host.send({ type: 'create', name: 'QA Kirobo hôte', player_count: 3, stake: 50, wallet_key: keys[0] });
  const { code } = await host.until('welcome');
  assert.equal((await host.until('lobby')).data.stake, 50);
  const same = await new Client().open();
  same.send({ type: 'join', code, wallet_key: keys[0] });
  assert.match((await same.until('error')).message, /déjà une place/);
  const guests = [];
  for (const key of keys.slice(1)) {
    const client = await new Client().open();
    client.send({ type: 'join', name: 'QA Kirobo invité', code, wallet_key: key });
    await client.until('welcome');
    await client.until('lobby');
    guests.push(client);
  }
  await host.until('lobby', frame => frame.data.players.length === 3);
  host.send({ type: 'start' });
  assert.match((await host.until('error')).message, /accepter la mise/);
  assert.equal(await wallet(keys[0]), 705, 'waiting lobby does not reserve funds');
  for (const client of guests) client.send({ type: 'accept_stake', stake: 50 });
  const ready = await host.until('lobby', frame => frame.data.players.every(p => p.stake_ready));
  assert.ok(!ready.data.players.some(p => 'wallet' in p));
  host.send({ type: 'start' });
  const first = (await host.until('state')).data;
  assert.equal(first.stake, 50);
  assert.equal(await wallet(keys[0]), 655);
  assert.equal(await wallet(keys[1]), 450);
  assert.equal(await wallet(keys[2]), 450);
  for (const client of guests) client.leave();
  const result = (await host.until('state', frame => frame.data.match_result.finished)).data;
  assert.equal(result.win_by_forfeit, true);
  assert.equal(result.stake_net, 100);
  assert.equal(await wallet(keys[0]), 805);
  assert.equal(await wallet(keys[1]), 450);
  assert.equal(await wallet(keys[2]), 450);
  host.send({ type: 'rematch', session_id: result.session_id });
  await host.until('lobby', frame => !frame.data.started && frame.data.players.length === 1);
  assert.equal(await wallet(keys[0], wins), 805, 'replay and resync preserve the settled pot');
  host.leave();
  console.log('PASS Kirobo: offline receipts, private wallets, consent, debit, forfeit payout and rematch');
}

async function testRooms() {
  for (const size of [0, 6, 12]) {
    const { client: a, welcome: aw } = await create(size);
    let { client: b, welcome: bw } = await join(aw.code);
    const extras = [];
    if (!size) for (let i = 0; i < 2; i++) extras.push((await join(aw.code)).client);
    const count = size ? 2 : 4;
    await a.until('lobby', frame => frame.data.players.length === count);
    b.send({ type: 'start' });
    assert.match((await b.until('error')).message, /hôte/);
    const outsider = await new Client().open();
    outsider.send({ type: 'join', name: 'QA Supabase Extra', code: aw.code });
    assert.match((await outsider.until('error')).message, /complet/);
    a.send({ type: 'start' });
    const av = (await a.until('state')).data;
    const bv = (await b.until('state')).data;
    assert.equal(av.hand.length, size || 13);
    assert.equal(bv.hand.length, size || 13);
    assert.equal(av.variant, size ? 'tri' : 'rami');
    assert.ok(!av.players.some(p => 'hand' in p));
    assert.ok(!JSON.stringify(av).includes(bw.token));
    assert.ok(!JSON.stringify(av).includes('_rng_state'));
    assert.ok(!('deck' in av));
    assert.equal(new Set([...av.hand, ...bv.hand]).size, (size || 13) * 2);
    b.send({ type: 'action', action: { type: 'discard', card: av.hand[0], player: 0 } });
    assert.ok((await b.until('error')).message);
    a.send({ type: 'action', action: { type: 'draw', source: 'deck' } });
    const drawn = (await a.until('state', frame => frame.data.phase === 'play')).data;
    assert.equal(drawn.hand.length, (size || 13) + 1);
    assert.deepEqual((await b.until('state', frame => frame.data.phase === 'play')).data.hand, bv.hand);
    await delay(80);
    a.send({ type: 'action', action: { type: 'discard', card: drawn.hand.at(-1) } });
    await b.until('state', frame => frame.data.turn === 1);
    b.close();
    await a.until('state', frame => frame.data.paused);
    const resumed = await join(aw.code, bw.token);
    b = resumed.client;
    assert.equal(resumed.welcome.player, 1);
    assert.equal(resumed.welcome.token, bw.token);
    const recovered = (await b.until('state', frame => !frame.data.paused)).data;
    assert.deepEqual(recovered.hand, bv.hand);
    assert.equal(recovered.turn, 1);
    await a.until('state', frame => !frame.data.paused && frame.data.turn === 1);
    const invalid = await new Client().open();
    invalid.send({ type: 'join', code: aw.code, token: 'f'.repeat(48) });
    assert.equal((await invalid.until('error')).fatal, true);
    assert.ok(!invalid.frames.some(frame => frame.type === 'state'));
    b.leave();
    for (const client of extras) client.leave();
    const win = (await a.until('state', frame => frame.data.winner === 0)).data;
    assert.equal(win.win_by_forfeit, true);
    a.leave();
    console.log(`PASS hosted ${size ? `Tri ${size}` : 'Rami 4 players'}: privacy, rules, capacity, token resume, forfeit`);
  }
  if (process.argv.includes('--rotation')) {
    const { client: a, welcome: aw } = await create(6);
    const { client: b } = await join(aw.code);
    console.log('Checking hosted 100-second worker rotation in the lobby…');
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Expected planned socket rotation')), 115000);
      a.socket.addEventListener('close', () => { clearTimeout(timer); resolve(); }, { once: true });
    });
    const resumedA = await join(aw.code, aw.token);
    assert.equal(resumedA.welcome.player, 0);
    assert.equal(resumedA.welcome.token, aw.token);
    resumedA.client.leave();
    b.leave();
    console.log('PASS planned worker rotation preserves the lobby owner and private token');
  }
}

try {
  if (process.argv.includes('--kirobo') || process.argv.includes('--tselis')) await testStakes();
  else await testRooms();
} finally {
  for (const client of clients) { client.leave(); client.close(); }
}
