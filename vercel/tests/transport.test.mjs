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
