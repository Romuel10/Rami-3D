import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { WebSocket } from 'ws';
import Redis from 'ioredis';
import { createGameServer } from '../lib/server.mjs';
import { RedisRoomStore } from '../lib/store.mjs';

const delay = ms => new Promise(resolve => setTimeout(resolve,ms));
async function freePort() {
  const server = net.createServer(); server.listen(0,'127.0.0.1'); await once(server,'listening');
  const port = server.address().port; await new Promise(resolve=>server.close(resolve)); return port;
}
class Client {
  constructor(socket) {
    this.socket = socket; this.queue = []; this.waiters = []; this.all = [];
    socket.on('error',()=>{});
    socket.on('message',data=>{ const value=JSON.parse(data.toString()); this.all.push(value); this.queue.push(value); this.flush(); });
  }
  static async connect(app) { const socket = new WebSocket(`ws://127.0.0.1:${app.server.address().port}/api/ws`); const client = new Client(socket); await once(socket,'open'); return client; }
  send(message) { this.socket.send(JSON.stringify(message)); }
  flush() {
    for (const waiter of [...this.waiters]) {
      const index = this.queue.findIndex(value=>value.type===waiter.type && waiter.predicate(value));
      if(index<0) continue;
      this.waiters.splice(this.waiters.indexOf(waiter),1); clearTimeout(waiter.timer); waiter.resolve(this.queue.splice(index,1)[0]);
    }
  }
  until(type,predicate=()=>true) { return new Promise((resolve,reject)=>{
    const waiter={type,predicate,resolve,timer:setTimeout(()=>reject(new Error(`Timed out waiting for ${type}; frames=${JSON.stringify(this.all)}`)),4000)};
    this.waiters.push(waiter); this.flush();
  }); }
  close() { this.socket.terminate(); }
}

async function fixture(t, options={}) {
  const port=await freePort();
  const binary=process.env.REDIS_SERVER_BIN||'redis-server';
  const redisProcess=spawn(binary,['--port',String(port),'--bind','127.0.0.1','--save','','--appendonly','no'],{stdio:['ignore','pipe','pipe']});
  let processError;
  redisProcess.on('error',error=>{processError=error;});
  const redisUrl=`redis://127.0.0.1:${port}`;
  const probe=new Redis(redisUrl,{retryStrategy:()=>25,maxRetriesPerRequest:30,connectTimeout:250}); probe.on('error',()=>{});
  await Promise.race([probe.ping(),delay(4000).then(()=>{throw processError||new Error('Redis test server did not start. Set REDIS_SERVER_BIN or install redis-server.');})]);
  const prefix=`test:${randomUUID()}:`;
  const apps=[],clients=[];
  async function app() {
    const instance=createGameServer({redisUrl,prefix,graceMs:600,leaseMs:200,heartbeatMs:50,sweepMs:25,...options});
    await instance.ready;
    instance.server.listen(0,'127.0.0.1'); await once(instance.server,'listening'); apps.push(instance); return instance;
  }
  t.after(async()=>{
    for(const client of clients)client.close();
    await Promise.allSettled(apps.map(instance=>instance.close()));
    probe.disconnect(); redisProcess.kill();
    if(redisProcess.exitCode===null) await once(redisProcess,'exit');
  });
  async function connect(instance) { const client=await Client.connect(instance); clients.push(client); return client; }
  return { app,connect,probe,prefix };
}
async function create(client,tri=0) {
  client.send({type:'create',name:'Alice',tri_cards:tri});
  const welcome=await client.until('welcome'); await client.until('lobby'); return welcome;
}
async function join(client,code,token='') {
  client.send({type:'join',name:'Bob',code,token});
  const welcome=await client.until('welcome'); await client.until('lobby'); return welcome;
}
async function start(owner,guest) {
  owner.send({type:'start'});
  return [(await owner.until('state')).data,(await guest.until('state')).data];
}

test('two Function instances share private rummy state and serialize concurrent actions',async t=>{
  const f=await fixture(t); const first=await f.app(),second=await f.app();
  const a=await f.connect(first),b=await f.connect(second); const aw=await create(a); const bw=await join(b,aw.code);
  const [av,bv]=await start(a,b);
  assert.equal(av.hand.length,13); assert.equal(bv.hand.length,13);
  assert.equal(av.players.length,2); assert.notDeepEqual(av.hand,bv.hand);
  assert.ok(!av.players.some(p=>'hand' in p)); assert.ok(!JSON.stringify(av).includes('_rng_state'));
  assert.ok(!JSON.stringify(av).includes(bw.token)); assert.equal(av.paused,false);
  a.send({type:'action',action:{type:'draw',source:'deck'}});
  b.send({type:'action',action:{type:'discard',card:bv.hand[0],player:0}});
  const drawn=(await a.until('state',m=>m.data.phase==='play')).data;
  const privateOther=(await b.until('state',m=>m.data.phase==='play')).data;
  assert.equal(drawn.hand.length,14); assert.deepEqual(privateOther.hand,bv.hand);
  assert.ok((await b.until('error')).message);
  await delay(55); a.send({type:'action',action:{type:'discard',card:drawn.hand.at(-1)}});
  assert.equal((await b.until('state',m=>m.data.turn===1)).data.turn,1);
  const stored=JSON.parse(await f.probe.get(`${f.prefix}room:${aw.code}`));
  const cards=[...stored.game.deck,...stored.game.discard,...stored.game.players.flatMap(p=>p.hand),...stored.game.melds.flatMap(m=>m.cards)];
  assert.equal(cards.length,108); assert.equal(new Set(cards).size,108);
});

test('Tri 6/12 duels survive a Function loss and reject a third player',async t=>{
  const f=await fixture(t);
  for(const size of [6,12]) {
    const first=await f.app(),second=await f.app();
    const a=await f.connect(first),b=await f.connect(second); const aw=await create(a,size); const bw=await join(b,aw.code);
    const outsider=await f.connect(second); outsider.send({type:'join',name:'Extra',code:aw.code}); assert.equal((await outsider.until('error')).fatal,true);
    const [av,bv]=await start(a,b); assert.equal(av.tri_goal,size===6?2:3); assert.equal(av.hand.length,size); assert.equal(bv.hand.length,size);
    assert.deepEqual(av.winning_tris,[]);
    a.send({type:'action',action:{type:'draw',source:'deck'}});
    const drawn=(await a.until('state',m=>m.data.phase==='play')).data;
    await first.close({abrupt:true});
    const resumed=await f.connect(second); await join(resumed,aw.code,aw.token);
    const restored=(await resumed.until('state')).data;
    assert.deepEqual(restored.hand,drawn.hand); assert.equal(restored.phase,'play'); assert.equal(restored.variant,'tri');
    b.send({type:'leave'});
    const won=(await resumed.until('state',m=>m.data.winner===0)).data;
    assert.equal(won.win_by_forfeit,true); assert.deepEqual(won.match_result.winners,[0]);
    assert.ok(!JSON.stringify(won).includes(bw.token));
  }
});

test('a valid token replaces only its own old connection; old close cannot erase the new seat',async t=>{
  const f=await fixture(t); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two); const aw=await create(a); await join(b,aw.code); const [before]=await start(a,b);
  const replacement=await f.connect(two); await join(replacement,aw.code,aw.token);
  const restored=(await replacement.until('state')).data; assert.deepEqual(restored.hand,before.hand);
  await a.until('error',m=>m.fatal);
  await delay(120);
  replacement.send({type:'action',action:{type:'draw',source:'deck'}});
  assert.equal((await replacement.until('state',m=>m.data.phase==='play')).data.hand.length,14);
  const stored=JSON.parse(await f.probe.get(`${f.prefix}room:${aw.code}`));
  assert.ok(stored.players[0].connection); assert.equal(stored.players[0].deadline,0);
});

test('lobby departure releases a seat and transfers owner across instances',async t=>{
  const f=await fixture(t); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two); const aw=await create(a); const bw=await join(b,aw.code);
  a.send({type:'leave'});
  const changed=await b.until('welcome',m=>m.player===0&&m.is_host);
  assert.equal(changed.token,bw.token);
  const lobby=(await b.until('lobby',m=>m.data.players.length===1)).data; assert.equal(lobby.host,true);
  const c=await f.connect(one); await join(c,aw.code);
  b.send({type:'start'}); assert.equal((await b.until('state')).data.players.length,2);
});

test('a Supabase-style lobby survives socket rotation, but leave and grace expiry release seats',async t=>{
  const f=await fixture(t,{preserveLobby:true,graceMs:300});
  const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two);
  const aw=await create(a,6),bw=await join(b,aw.code);
  b.close();
  const waiting=(await a.until('lobby',m=>m.data.players.length===2&&!m.data.players[1].connected)).data;
  assert.equal(waiting.started,false);
  a.send({type:'start'}); assert.match((await a.until('error')).message,/reconnexion/);
  const resumed=await f.connect(two); const restored=await join(resumed,aw.code,bw.token);
  assert.equal(restored.player,1); assert.equal(restored.token,bw.token);
  resumed.send({type:'leave'});
  await a.until('lobby',m=>m.data.players.length===1);
  const replacement=await f.connect(two); await join(replacement,aw.code);
  replacement.close();
  await a.until('lobby',m=>m.data.players.length===1);
});

test('transient transport loss pauses, same hand resumes, long loss forfeits',async t=>{
  const f=await fixture(t,{graceMs:400}); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two); const aw=await create(a); const bw=await join(b,aw.code); const [,before]=await start(a,b);
  b.close(); assert.equal((await a.until('state',m=>m.data.paused)).data.paused,true);
  const replacement=await f.connect(two); await join(replacement,aw.code,bw.token);
  const resumed=(await replacement.until('state')).data; assert.deepEqual(resumed.hand,before.hand); assert.equal(resumed.paused,false);
  await a.until('state',m=>!m.data.paused); replacement.close();
  const won=(await a.until('state',m=>m.data.winner===0)).data; assert.equal(won.win_by_forfeit,true);
  const late=await f.connect(one); late.send({type:'join',code:aw.code,token:bw.token}); assert.equal((await late.until('error')).fatal,true);
});

test('three-player elimination skips departed seat and the last active player wins',async t=>{
  const f=await fixture(t); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two),c=await f.connect(two); const aw=await create(a); await join(b,aw.code); await join(c,aw.code);
  a.send({type:'start'}); await a.until('state'); await b.until('state'); await c.until('state');
  b.send({type:'leave'});
  const continued=(await a.until('state',m=>m.data.players[1].forfeited)).data;
  assert.equal(continued.winner,-1); assert.equal(continued.paused,false);
  a.send({type:'action',action:{type:'draw',source:'deck'}});
  const drawn=(await a.until('state',m=>m.data.phase==='play')).data;
  await delay(55); a.send({type:'action',action:{type:'discard',card:drawn.hand.at(-1)}});
  assert.equal((await c.until('state',m=>m.data.turn===2)).data.turn,2);
  c.send({type:'leave'}); assert.equal((await a.until('state',m=>m.data.winner===0)).data.win_by_forfeit,true);
});

test('expired Function leases settle on a different instance and persist the forfeit',async t=>{
  const f=await fixture(t,{graceMs:300,leaseMs:120}); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two); const aw=await create(a); await join(b,aw.code); await start(a,b);
  await one.close({abrupt:true});
  const won=(await b.until('state',m=>m.data.winner===1)).data;
  assert.deepEqual(won.match_result.winners,[1]); assert.equal(won.win_by_forfeit,true);
  const third=await f.app(),newcomer=await f.connect(third); newcomer.send({type:'join',code:aw.code,token:aw.token});
  assert.equal((await newcomer.until('error')).fatal,true);
});

test('Redis lock fencing refuses a stale writer and production has no memory fallback',async t=>{
  const f=await fixture(t); const store=new RedisRoomStore(`redis://127.0.0.1:${f.probe.options.port}`,{prefix:f.prefix}); await store.ready();
  t.after(()=>store.close());
  const room=await store.create({players:[{name:'A'}],started:false,game:null,tri_cards:0});
  await assert.rejects(store.update(room.code,async value=>{await store.redis.set(`${f.prefix}lock:${room.code}`,'other','PX',5000); value.players[0].name='stale';}),/changé/);
  assert.equal((await store.read(room.code)).players[0].name,'A');
  assert.throws(()=>new RedisRoomStore(''),/REDIS_URL/);
});

test('health reports readiness and malformed unauthenticated frames cannot create rooms',async t=>{
  const f=await fixture(t,{authMs:80}); const app=await f.app();
  const response=await fetch(`http://127.0.0.1:${app.server.address().port}/health`);
  assert.equal(response.status,200); assert.equal((await response.json()).ready,true);
  const bad=await f.connect(app); const closed=once(bad.socket,'close'); bad.socket.send('{broken');
  assert.equal((await closed)[0],1007);
  const silent=await f.connect(app); assert.equal((await once(silent.socket,'close'))[0],1008);
  assert.equal(await f.probe.zcard(`${f.prefix}rooms`),0);
  const owner=await f.connect(app); const welcome=await create(owner);
  const forged=await f.connect(app); forged.send({type:'join',code:welcome.code,token:'é'.repeat(48)});
  assert.equal((await forged.until('error')).fatal,true);
});

if(process.env.GODOT_BIN) {
  test('real Godot client interoperates with Vercel protocol in rummy and both Tri formats',async t=>{
    const {mkdtemp,rm}=await import('node:fs/promises'); const {tmpdir}=await import('node:os'); const path=await import('node:path');
    const f=await fixture(t,{graceMs:60000,leaseMs:15000,heartbeatMs:5000,sweepMs:1000}); const app=await f.app();
    const directory=await mkdtemp(path.join(tmpdir(),'rami-vercel-godot-'));
    const root=path.resolve(import.meta.dirname,'../..');
    const args=['--headless','--audio-driver','Dummy','--path',root,'--script','tests/test_vercel_client.gd','--',`--url=ws://127.0.0.1:${app.server.address().port}/api/ws`];
    const process=spawn(globalThis.process.env.GODOT_BIN,args,{env:{...globalThis.process.env,XDG_DATA_HOME:directory},stdio:['ignore','pipe','pipe']});
    let output=''; process.stdout.on('data',data=>output+=data); process.stderr.on('data',data=>output+=data);
    const timeout=setTimeout(()=>process.kill('SIGKILL'),45000); timeout.unref();
    const [code]=await once(process,'exit'); clearTimeout(timeout);
    await rm(directory,{recursive:true,force:true});
    assert.equal(code,0,output); assert.match(output,/VERCEL GODOT CLIENT: \d+ checks; 0 failures/); assert.doesNotMatch(output,/SCRIPT ERROR|Parse Error|ERROR:/);
  });
}

test('a cold Function accepts its first upgrade after initializing Redis',async t=>{
  const f=await fixture(t);
  const url=`redis://127.0.0.1:${f.probe.options.port}`;
  const cold=createGameServer({redisUrl:url,prefix:f.prefix});
  t.after(()=>cold.close());
  cold.server.listen(0,'127.0.0.1'); await once(cold.server,'listening');
  // Deliberately do not await cold.ready: this is the first real invocation.
  const client=await Client.connect(cold); t.after(()=>client.close());
  const welcome=await create(client); assert.match(welcome.code,/^\d{6}$/);
});

test('atomic room updates across clients never lose concurrent commits',async t=>{
  const f=await fixture(t); const url=`redis://127.0.0.1:${f.probe.options.port}`;
  const a=new RedisRoomStore(url,{prefix:f.prefix}),b=new RedisRoomStore(url,{prefix:f.prefix});
  await Promise.all([a.ready(),b.ready()]); t.after(()=>Promise.all([a.close(),b.close()]));
  const room=await a.create({players:[{name:'A'}],started:false,game:null,counter:0});
  await Promise.all(Array.from({length:24},(_,index)=>(index%2?a:b).update(room.code,value=>{value.counter++;})));
  assert.equal((await a.read(room.code)).counter,24);
});

class TestVoiceBus {
  constructor() { this.topics = new Map(); this.sent = 0; }
  subscribe(topic, receive, status) {
    if (!this.topics.has(topic)) this.topics.set(topic,new Set());
    const listeners=this.topics.get(topic); listeners.add(receive);
    queueMicrotask(()=>status(true));
    return {send: payload=>{ this.sent++; for (const fn of listeners) queueMicrotask(()=>fn(payload)); },close:()=>listeners.delete(receive)};
  }
}
async function completeRound(f,code) {
  const {validateState}=await import('../lib/engine.mjs');
  const room=JSON.parse(await f.probe.get(`${f.prefix}room:${code}`));
  room.game.deck.push(...room.game.players[0].hand.splice(0));
  room.game.winner=0; room.game.revision++;
  room.game.match.totals=room.players.map(()=>0);
  room.game.match.results=[{winner:0,points:room.players.map(()=>0)}];
  assert.ok(validateState(room.game),'controlled completed deal obeys state invariants');
  room.version++;
  await f.probe.set(`${f.prefix}room:${code}`,JSON.stringify(room));
  await f.probe.publish(`${f.prefix}updates`,code);
  return room.game.session_id;
}

async function finishRummyTurn(app, client, code, seat) {
  const { validateState } = await import('../lib/engine.mjs');
  const { room } = await app.hub.store.update(code, room => {
    const game = room.game;
    game.deck.push(...game.players[seat].hand.splice(1));
    game.turn = seat;
    game.phase = 'play';
    game.revision++;
    assert.ok(validateState(game));
  });
  const game = room.game;
  await client.until('state', m => m.data.session_id === game.session_id && m.data.revision === game.revision);
  // The controlled finish can happen faster than two real turns on CI.
  await delay(55);
  client.send({ type: 'action', session_id: game.session_id, round: game.match.round, action: { type: 'discard', card: game.players[seat].hand[0] } });
  return (await client.until('state', m => m.data.session_id === game.session_id && m.data.revision === game.revision + 1)).data;
}

test('the owner removes a guest and runs a persistent series without heartbeat state duplicates', async t => {
  const f = await fixture(t, { preserveLobby: true });
  const first = await f.app(), second = await f.app();
  const host = await f.connect(first), removed = await f.connect(second), guest = await f.connect(second);
  host.send({ type: 'create', name: 'Alice', province: 'Toliara', player_count: 2, rounds: 3 });
  const { code } = await host.until('welcome');
  removed.send({ type: 'join', name: 'Invité', code, series: true });
  await removed.until('welcome');
  const roster = (await host.until('lobby', m => m.data.players.length === 2)).data.players;
  removed.send({ type: 'kick', seat_id: roster[0].seat_id });
  assert.match((await removed.until('error')).message, /hôte/);
  host.send({ type: 'kick', seat_id: roster[1].seat_id });
  assert.match((await removed.until('error')).message, /retiré/);
  guest.send({ type: 'join', name: 'Bob', province: 'Mahajanga', code, series: true });
  await guest.until('welcome');
  const [firstHand, otherHand] = await start(host, guest);
  assert.deepEqual(otherHand.players.map(p => p.province), ['Toliara', 'Mahajanga']);
  const count = host.all.filter(m => m.type === 'state').length;
  await first.hub.store.update(code, () => {}); // Same state, newer room version.
  await delay(120);
  assert.equal(host.all.filter(m => m.type === 'state').length, count);
  const roundOne = await finishRummyTurn(first, host, code, 0);
  assert.equal(roundOne.match_result.finished, false);
  guest.send({ type: 'next_round', session_id: firstHand.session_id, round: 1 });
  assert.match((await guest.until('error')).message, /hôte/);
  for (const round of [2, 3]) {
    host.send({ type: 'next_round', session_id: firstHand.session_id, round: round - 1 });
    const fresh = (await guest.until('state', m => m.data.match.round === round && m.data.winner < 0)).data;
    assert.equal(fresh.session_id, firstHand.session_id);
    assert.equal(fresh.match.results.length, round - 1);
    assert.equal(fresh.turn, (round - 1) % 2);
    guest.send({ type: 'action', session_id: firstHand.session_id, round: round - 1, action: { type: 'draw' } });
    assert.match((await guest.until('error')).message, /autre manche/);
    const result = await finishRummyTurn(first, guest, code, 1);
    assert.equal(result.match_result.finished, round === 3);
    assert.equal(result.match.totals[1], roundOne.match.totals[1]);
  }
});

test('four-seat tournament separates duels, advances a finalist, and frees the room at the last departure', async t => {
  const f = await fixture(t, { preserveLobby: true });
  const first = await f.app(), second = await f.app();
  const members = await Promise.all([first, second, first, second].map(app => f.connect(app)));
  const [host, b, c, d] = members;
  host.send({ type: 'create', name: 'Alice', province: 'Antananarivo', tournament: true, tournament_name: 'Coupe de Rami' });
  const { code } = await host.until('welcome');
  const legacy = await f.connect(first);
  legacy.send({ type: 'join', name: 'Ancien jeu', code });
  assert.match((await legacy.until('error')).message, /jour/);
  for (const [i, player] of members.slice(1).entries()) {
    player.send({ type: 'join', name: ['Bob', 'Caro', 'Dina'][i], province: ['Toliara', 'Toamasina', 'Antsiranana'][i], code, series: true });
    await player.until('welcome');
  }
  host.send({ type: 'start' });
  const initial = (await b.until('state')).data;
  assert.equal(initial.your_index, 1);
  assert.equal(initial.players.length, 2);
  const bracket = (await d.until('lobby', m => m.data.started)).data;
  assert.equal(bracket.tournament.name, 'Coupe de Rami');
  assert.equal(bracket.playing, false);
  assert.equal(d.all.filter(m => m.type === 'state').length, 0);
  assert.ok(bracket.players.every(p => !('hand' in p) && !('token' in p)));
  c.send({ type: 'action', session_id: initial.session_id, action: { type: 'draw' } });
  assert.match((await c.until('error')).message, /duel/);
  await finishRummyTurn(first, b, code, 1);
  await host.until('lobby', m => m.data.tournament.duels[0].winner === 1);
  b.send({ type: 'advance_tournament', stage: 0 });
  assert.match((await b.until('error')).message, /hôte/);
  host.send({ type: 'advance_tournament', stage: 0 });
  const semi = (await d.until('state')).data;
  assert.equal(semi.your_index, 1);
  assert.deepEqual(semi.players.map(p => p.name), ['Caro', 'Dina']);
  assert.notEqual(semi.session_id, initial.session_id);
  await finishRummyTurn(first, d, code, 1);
  await host.until('lobby', m => m.data.tournament.duels[1].winner === 3);
  host.send({ type: 'advance_tournament', stage: 1 });
  const final = (await b.until('state', m => m.data.session_id !== initial.session_id)).data;
  assert.deepEqual(final.players.map(p => p.name), ['Bob', 'Dina']);
  assert.equal(final.your_index, 0);
  await finishRummyTurn(first, b, code, 0);
  const ended = (await c.until('lobby', m => m.data.finished)).data;
  assert.equal(ended.tournament.champion, 1);
  assert.equal(ended.playing, false);
  for (const player of members) {
    const closed = once(player.socket, 'close');
    player.send({ type: 'leave' });
    await closed;
  }
  assert.equal(await first.hub.store.read(code), null);
  assert.equal(await f.probe.zcard(`${f.prefix}rooms`), 0);
});

test('chosen capacity is enforced and only the lobby owner can change it',async t=>{
  const f=await fixture(t); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two),c=await f.connect(two);
  a.send({type:'create',name:'Alice',player_count:4}); const aw=await a.until('welcome');
  assert.equal((await a.until('lobby')).data.player_count,4);
  await join(b,aw.code); a.send({type:'start'}); assert.match((await a.until('error')).message,/4 joueurs/);
  b.send({type:'configure',player_count:2}); assert.match((await b.until('error')).message,/hôte/);
  await join(c,aw.code); a.send({type:'configure',player_count:2}); assert.match((await a.until('error')).message,/trop petit/);
  a.send({type:'configure',player_count:3}); await a.until('lobby',m=>m.data.player_count===3);
  const extra=await f.connect(two); extra.send({type:'join',code:aw.code}); assert.equal((await extra.until('error')).fatal,true);
  a.send({type:'start'}); assert.equal((await c.until('state')).data.players.length,3);
  for(const count of [1,5,'3',2.5]) { const bad=await f.connect(one); bad.send({type:'create',player_count:count}); assert.equal((await bad.until('error')).fatal,true); }
});

test('Tri at three and four seats enforces the selected roster and continues after a player leaves with a drawn card', async t => {
  const f = await fixture(t, { preserveLobby: true });
  const first = await f.app(), second = await f.app();
  for (const [size, count] of [[6, 3], [12, 4]]) {
    const host = await f.connect(first);
    host.send({ type: 'create', name: 'Tri host', tri_cards: size, player_count: count });
    const { code } = await host.until('welcome');
    const room = (await host.until('lobby')).data;
    assert.equal(room.capacity, count);
    assert.equal(room.player_count, count);
    const guest = await f.connect(second);
    const joined = await join(guest, code);
    host.send({ type: 'start' });
    assert.match((await host.until('error')).message, new RegExp(`${count} joueurs`));
    host.send({ type: 'configure', player_count: 2 });
    await host.until('lobby', m => m.data.player_count === 2);
    host.queue = host.queue.filter(m => m.type !== 'lobby');
    host.send({ type: 'configure', player_count: count });
    await host.until('lobby', m => m.data.player_count === count);
    const members = [host, guest];
    for (let i = 2; i < count; i++) {
      const player = await f.connect(i % 2 ? first : second);
      await join(player, code);
      members.push(player);
    }
    const extra = await f.connect(second);
    extra.send({ type: 'join', code });
    assert.match((await extra.until('error')).message, /complet/);
    host.send({ type: 'start' });
    const views = await Promise.all(members.map(async player => (await player.until('state')).data));
    assert.ok(views.every(view => view.variant === 'tri' && view.hand.length === size && view.players.length === count));
    assert.ok(views.every(view => view.players.every(player => !('hand' in player))));
    assert.equal(new Set(views.flatMap(view => view.hand)).size, size * count);
    host.send({ type: 'action', action: { type: 'draw', source: 'deck' } });
    await host.until('state', m => m.data.hand.length === size + 1);
    host.send({ type: 'leave' });
    const continued = (await guest.until('state', m => m.data.players[0].forfeited)).data;
    assert.equal(continued.turn, 1);
    assert.equal(continued.winner, -1);
    assert.equal(continued.paused, false);
    const recovered = await f.connect(first);
    await join(recovered, code, joined.token);
    assert.deepEqual((await recovered.until('state')).data.hand, views[1].hand);
    recovered.send({ type: 'action', action: { type: 'draw', source: 'deck' } });
    await recovered.until('state', m => m.data.hand.length === size + 1);
  }
});

test('unanimous rematch keeps private seats and survives a postgame reconnect; stale votes/moves are rejected',async t=>{
  const f=await fixture(t,{preserveLobby:true}); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two); a.send({type:'create',name:'Alice',player_count:2}); const aw=await a.until('welcome'); await a.until('lobby');
  const bw=await join(b,aw.code); const [first]=await start(a,b); const old=await completeRound(f,aw.code);
  await a.until('state',m=>m.data.winner===0); await b.until('state',m=>m.data.winner===0);
  a.send({type:'rematch',session_id:old}); await a.until('lobby',m=>m.data.players[0].rematch_ready);
  a.close(); const restored=await f.connect(two); const rw=await join(restored,aw.code,aw.token);
  assert.equal(rw.token,aw.token); assert.equal((await restored.until('state')).data.session_id,old);
  b.send({type:'rematch',session_id:old});
  const fresh=(await restored.until('state',m=>m.data.winner<0)).data;
  const other=(await b.until('state',m=>m.data.session_id!==old)).data;
  assert.notEqual(fresh.session_id,first.session_id); assert.equal(fresh.hand.length,13); assert.notDeepEqual(fresh.hand,other.hand);
  assert.equal(rw.code,aw.code); assert.equal(bw.code,aw.code); assert.ok(!JSON.stringify(fresh).includes(bw.token));
  restored.send({type:'rematch',session_id:old}); assert.match((await restored.until('error')).message,/fin du match/);
  restored.send({type:'action',session_id:old,action:{type:'draw',source:'deck'}}); assert.match((await restored.until('error')).message,/précédent/);
  restored.send({type:'action',session_id:fresh.session_id,action:{type:'draw',source:'deck'}}); assert.equal((await restored.until('state',m=>m.data.phase==='play')).data.hand.length,14);
});

test('a declined rematch returns remaining players to the same lobby without leaking a reindexed hand',async t=>{
  const f=await fixture(t); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two),c=await f.connect(two);
  a.send({type:'create',name:'Alice',player_count:3}); const aw=await a.until('welcome'); await a.until('lobby');
  const bw=await join(b,aw.code); await join(c,aw.code); a.send({type:'start'}); await a.until('state'); await b.until('state'); await c.until('state');
  const old=await completeRound(f,aw.code); await a.until('state',m=>m.data.winner===0);
  b.send({type:'rematch',session_id:old}); await b.until('lobby',m=>m.data.players[1].rematch_ready);
  c.send({type:'rematch',session_id:old}); await c.until('lobby',m=>m.data.players[2].rematch_ready);
  const count=a.all.filter(m=>m.type==='state').length;
  a.send({type:'leave'});
  const transfer=await b.until('welcome',m=>m.player===0); assert.equal(transfer.token,bw.token);
  const lobby=(await b.until('lobby',m=>!m.data.started && m.data.host && m.data.players[0].name==='Bob')).data;
  assert.equal(lobby.code,aw.code); assert.equal(lobby.players.length,2); assert.equal(lobby.player_count,3);
  await delay(80);
  assert.ok(a.all.filter(m=>m.type==='state').slice(count).every(m=>m.data.hand.length===0 && m.data.your_index===0 && m.data.session_id===old),'departing seat receives no reindexed private hand');
  const d=await f.connect(one); await join(d,aw.code); b.send({type:'start'});
  assert.equal((await d.until('state')).data.players.length,3);
});

test('voice crosses workers only for authenticated members, is transient, bounded, and excludes replaced seats',async t=>{
  const voice=new TestVoiceBus(); const f=await fixture(t,{voice}); const one=await f.app(),two=await f.app();
  const a=await f.connect(one),b=await f.connect(two),outside=await f.connect(two);
  const aw=await create(a); await join(b,aw.code); await create(outside);
  await a.until('voice_status',m=>m.available); await b.until('voice_status',m=>m.available);
  const data=Buffer.alloc(645); data[2]=32; data.writeUInt16LE(1280,3); const encoded=data.toString('base64');
  const before=await f.probe.get(`${f.prefix}room:${aw.code}`);
  a.send({type:'voice',seq:1,data:encoded,player:3});
  const received=await b.until('voice'); assert.equal(received.player,0); assert.equal(received.data,encoded);
  assert.ok(!JSON.stringify(received).includes(aw.token)); assert.ok(!before.includes(encoded));
  assert.ok(!outside.all.some(m=>m.type==='voice')); assert.ok(!a.all.some(m=>m.type==='voice'));
  await delay(60); const sent=voice.sent;
  a.send({type:'voice',seq:1,data:encoded}); a.send({type:'voice',seq:2,data:'bad'});
  await delay(70); assert.equal(voice.sent,sent);
  const replacement=await f.connect(two); await join(replacement,aw.code,aw.token); await replacement.until('voice_status',m=>m.available); await a.until('error',m=>m.fatal);
  replacement.send({type:'voice',seq:0,data:encoded}); const next=await b.until('voice',m=>m.stream!==received.stream);
  assert.equal(next.player,0); assert.equal(next.seq,0);
  const stored=JSON.parse(await f.probe.get(`${f.prefix}room:${aw.code}`)); assert.ok(!('voice' in stored)); assert.ok(!JSON.stringify(stored).includes(encoded));
});
