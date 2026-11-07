/** Real hosted social/voice checks. Own QA rooms only; no admin key. */
import assert from 'node:assert/strict';
import {triGroups} from '../../vercel/lib/engine.mjs';
import { Buffer } from 'node:buffer';
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


async function create(count=2,tri=6) {
  const c=await new Client().open();c.send({type:'create',name:'QA Social Alice',player_count:count,tri_cards:tri});
  const w=await c.until('welcome');const lobby=(await c.until('lobby')).data;
  assert.equal(lobby.player_count,count);assert.equal(w.features.rematch,true);assert.equal(w.features.voice,true);
  return {c,w};
}
async function join(code,token='') {
  const c=await new Client().open();c.send({type:'join',name:'QA Social Bob',code,token});
  const w=await c.until('welcome');await c.until('lobby');return {c,w};
}
const score=hand=>{
  const groups=triGroups(hand);const used=new Set(groups.flat());const rest=hand.filter(c=>!used.has(c));let value=groups.length*100;
  for(let i=0;i<rest.length;i++) for(let j=0;j<i;j++) {
    const a=rest[i].split(':'),b=rest[j].split(':');
    if(a[2]===b[2]&&a[1]!==b[1]) value+=9;
    if(a[1]===b[1]) { const d=Math.abs(Number(a[2])-Number(b[2]));if(d===1)value+=8;else if(d===2)value+=5; }
  }
  return value;
};
const bestDiscard=hand=>hand.map((card,index)=>({card,value:score(hand.filter((_,i)=>i!==index))})).sort((a,b)=>b.value-a.value)[0];
try {
  const {c:a,w:aw}=await create(3,0);const {c:b}=await join(aw.code);
  a.send({type:'start'});assert.match((await a.until('error')).message,/3 joueurs/);
  b.send({type:'configure',player_count:2});assert.match((await b.until('error')).message,/hôte/);
  a.send({type:'configure',player_count:2});await a.until('lobby',m=>m.data.player_count===2);
  const outsider=await new Client().open();outsider.send({type:'join',code:aw.code});assert.equal((await outsider.until('error')).fatal,true);
  console.log('PASS hosted count: selected roster, owner-only settings, full-room rejection');
  const {c:separate}=await create();
  await a.until('voice_status',m=>m.available);await b.until('voice_status',m=>m.available);
  const frame=Buffer.alloc(645);frame[2]=32;frame.writeUInt16LE(1280,3);const data=frame.toString('base64');
  a.send({type:'voice',seq:1,data,player:3});const audio=await b.until('voice');assert.equal(audio.player,0);assert.equal(audio.data,data);
  await delay(150);assert.ok(!separate.frames.some(m=>m.type==='voice'));assert.ok(!a.frames.some(m=>m.type==='voice'));
  a.send({type:'voice',seq:2,data:'malformed'});await delay(150);assert.equal(b.frames.filter(m=>m.type==='voice').length,1);
  console.log('PASS hosted voice: private cross-connection relay, sender identity, isolation, malformed-frame rejection');
  a.leave();b.leave();separate.leave();
  if(!process.argv.includes('--skip-play')) {
    const {c:host,w:hw}=await create();const {c:guest,w:gw}=await join(hw.code);host.send({type:'start'});
    let views=[(await host.until('state')).data,(await guest.until('state')).data];const pair=[host,guest];let moves=0;
    while(views[0].winner<0 && moves<180) {
      const seat=views[0].turn;const c=pair[seat];const view=views[seat];
      let source='deck';
      if(view.discard_top && bestDiscard([...view.hand,view.discard_top]).value>score(view.hand))source='discard';
      c.send({type:'action',session_id:view.session_id,action:{type:'draw',source}});
      const drawn=(await c.until('state',m=>m.data.revision>view.revision&&m.data.phase==='play')).data;
      await delay(50);
      c.send({type:'action',session_id:view.session_id,action:{type:'discard',card:bestDiscard(drawn.hand).card}});
      views=await Promise.all(pair.map(async player=>(await player.until('state',m=>m.data.revision>drawn.revision)).data));
      moves++;if(moves%20===0)console.log(`Hosted Tri: ${moves} turns checked`);
    }
    assert.ok(views[0].winner>=0,'natural Tri game completes within bounded test');
    const old=views[0].session_id;
    host.send({type:'rematch',session_id:old});await host.until('lobby',m=>m.data.players[0].rematch_ready);
    host.close();const recovered=await join(hw.code,hw.token);assert.equal(recovered.w.token,hw.token);assert.equal((await recovered.c.until('state')).data.session_id,old);
    guest.send({type:'rematch',session_id:old});
    const fresh=(await recovered.c.until('state',m=>m.data.session_id!==old)).data;
    const other=(await guest.until('state',m=>m.data.session_id!==old)).data;
    assert.equal(fresh.winner,-1);assert.equal(fresh.tri_hand_size,6);assert.equal(fresh.hand.length,6);assert.notDeepEqual(fresh.hand,other.hand);
    assert.equal(recovered.w.code,hw.code);assert.ok(!JSON.stringify(fresh).includes(gw.token));
    console.log(`PASS hosted rematch after ${moves} real Tri turns: same code/tokens, postgame reconnect, fresh private deal`);
  }
} finally {
  for(const client of clients) {client.leave();client.close();}
}
