import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createGame, physicalDeck, cardInfo, validateMeld, triGroups, applyAction, forfeitPlayer, viewFor, matchResult, validateState } from '../lib/engine.mjs';
const clone = value => structuredClone(value);
function inventory(state) {
  const cards = [...state.deck, ...state.discard, ...state.players.flatMap(p => p.hand), ...state.melds.flatMap(g => g.cards)];
  assert.equal(cards.length, state.variant === 'tri' ? 104 : 108);
  assert.equal(new Set(cards).size, cards.length);
  assert.ok(cards.every(cardInfo));
  assert.equal(validateState(state), true);
}
function rig(hand, { triCards = 0, melds = [], phase = 'play', opened = false, draw = null } = {}) {
  const state = createGame(['Alice', 'Bob'], { triCards, seed: 17 });
  const used = [...hand, ...melds.flatMap(g => g.cards), ...(draw ? [draw] : [])];
  assert.equal(new Set(used).size, used.length);
  let rest = physicalDeck(!triCards).filter(id => !used.includes(id));
  state.players[0].hand = hand.slice();
  state.players[0].opened = opened;
  state.players[1].hand = rest.splice(0, triCards || 13);
  state.melds = clone(melds);
  state.discard = [rest.shift()];
  state.deck = draw ? [...rest, draw] : rest;
  state.phase = phase;
  inventory(state);
  return state;
}
function rejected(state, index, action, pattern) {
  const before = clone(state);
  const result = applyAction(state, index, action);
  assert.equal(result.ok, false);
  if (pattern) assert.match(result.error, pattern);
  assert.deepEqual(state, before, 'rejected action never mutates state');
}

test('physical cards are strict; seeded deals are reproducible and disjoint', () => {
  assert.equal(physicalDeck().length, 108);
  assert.equal(physicalDeck(false).length, 104);
  for (const id of physicalDeck()) assert.equal(cardInfo(id).id, id);
  for (const bad of [null, 1, '0:H:01', '0:H:14', '2:H:1', 'J:04', 'J:-1', '0:X:1', '__proto__']) assert.equal(cardInfo(bad), null);
  for (const count of [2, 3, 4]) {
    const names = Array.from({ length: count }, (_, i) => `P${i}`);
    const a = createGame(names, { seed: 17 });
    const b = createGame(names, { seed: 17 });
    assert.deepEqual(a, b);
    assert.ok(a.players.every(p => p.hand.length === 13));
    inventory(a);
  }
  assert.throws(() => createGame(['one']), TypeError);
  assert.throws(() => createGame(['a', 'b', 'c'], { triCards: 6 }), TypeError);
  assert.throws(() => createGame(['a', 'b'], { triCards: 9 }), TypeError);
  const state = createGame(['  ', '😀'.repeat(30)], { seed: 1 });
  assert.equal(state.players[0].name, 'Joueur 1');
  assert.equal(Array.from(state.players[1].name).length, 24);
});

test('meld validator matches rank/suit/ace/joker restrictions and maximizes run points', () => {
  const yes = [
    [['0:H:7', '0:C:7', '0:S:7'], 'set', 21],
    [['0:H:1', '0:C:1', 'J:0'], 'set', 33],
    [['0:H:1', '0:H:2', '0:H:3'], 'run', 6],
    [['0:H:12', '0:H:13', '0:H:1'], 'run', 31],
    [['0:H:7', 'J:0', '0:H:9'], 'run', 24],
    [['0:H:7', '0:H:8', 'J:0'], 'run', 24],
    [['0:H:12', '0:H:13', 'J:0'], 'run', 31],
    [['0:H:7', '0:C:7', 'J:0', 'J:1'], 'set', 28],
    [Array.from({ length: 13 }, (_, i) => `0:H:${i + 1}`), 'run', 95],
  ];
  for (const [cards, type, points] of yes) {
    const result = validateMeld(cards);
    assert.equal(result.ok, true, cards.join(','));
    assert.equal(result.type, type);
    assert.equal(result.points, points);
    assert.deepEqual(new Set(result.cards), new Set(cards));
  }
  const no = [[], ['0:H:7','0:H:8'], ['0:H:7','1:H:7','0:C:7'], ['0:H:13','0:H:1','0:H:2'], ['0:H:7','0:H:9','0:H:11'], ['0:H:7','0:H:7','0:C:7'], ['0:H:7','J:0','J:1'], ['J:0','J:1','J:2'], ['invalid','0:H:7','0:C:7']];
  for (const cards of no) assert.equal(validateMeld(cards).ok, false, cards.join(','));
  assert.equal(validateMeld(null).ok, false);
});

test('opening sums separate disjoint melds; rejections are atomic', () => {
  const hand = ['0:H:6','0:H:7','0:H:8','1:H:7','0:C:7','0:D:7','0:S:2','0:S:4','0:S:9','0:S:12','0:D:2','0:D:10','0:C:3','0:C:11'];
  const state = rig(hand);
  rejected(state, 1, { type: 'draw' }, /tour/);
  rejected(state, 0, { type: 'draw' }, /déjà/);
  rejected(state, 0, { type: 'meld', cards: hand.slice(0, 3) }, /30/);
  rejected(state, 0, { type: 'meld', groups: [hand.slice(0, 3), hand.slice(0, 3)] }, /disponibles/);
  rejected(state, 0, { type: 'meld', groups: null, cards: hand.slice(0, 3) });
  rejected(state, 0, { type: 'extend', meld: 0, cards: ['0:S:2'] }, /Ouvrez/);
  assert.equal(applyAction(state, 0, { type: 'meld', groups: [hand.slice(0, 3), hand.slice(3, 6)] }).ok, true);
  assert.equal(state.players[0].opened, true);
  assert.equal(state.players[0].hand.length, 8);
  assert.equal(state.melds.length, 2);
  assert.equal(state.last_action.type, 'meld');
  assert.equal(state.revision, 1);
  inventory(state);
});

test('keep final discard, extend public melds, then finish with a discard', () => {
  const state = rig(['0:H:10', '0:C:2'], { opened: true, melds: [{ owner: 1, type: 'run', cards: ['0:H:7','0:H:8','0:H:9'] }] });
  rejected(state, 0, { type: 'extend', meld: 0.5, cards: ['0:H:10'] });
  rejected(state, 0, { type: 'extend', meld: 0, cards: ['0:H:10','0:H:10'] });
  rejected(state, 0, { type: 'extend', meld: 0, cards: ['0:H:10','0:C:2'] }, /défausse finale/);
  assert.equal(applyAction(state, 0, { type: 'extend', meld: 0, cards: ['0:H:10'] }).ok, true);
  assert.deepEqual(state.players[0].hand, ['0:C:2']);
  assert.equal(state.winner, -1);
  inventory(state);
  assert.equal(applyAction(state, 0, { type: 'discard', card: '0:C:2' }).ok, true);
  assert.equal(state.winner, 0);
  assert.deepEqual(matchResult(state).winners, [0]);
  assert.equal(state.match.results.length, 1);
  assert.equal(state.match.results[0].points[0], 0);
  inventory(state);
  rejected(state, 1, { type: 'draw' }, /terminée/);
  assert.equal(state.match.results.length, 1);
});

test('turn order, draw-before-discard, wrong sources and malformed actions', () => {
  const state = createGame(['Alice', 'Bob', 'Camille'], { seed: 41 });
  rejected(state, 0, { type: 'discard', card: state.players[0].hand[0] }, /Piochez/);
  for (const action of [null, [], {}, { type: 1 }, { type: '__proto__' }, { type: 'draw', source: null }, { type: 'draw', source: [] }]) rejected(state, 0, action);
  rejected(state, 1, { type: 'draw' }, /tour/);
  rejected(state, 0.5, { type: 'draw' }, /inconnu/);
  const top = state.discard.at(-1);
  assert.equal(applyAction(state, 0, { type: 'draw', source: 'discard' }).ok, true);
  assert.equal(state.players[0].hand.at(-1), top);
  rejected(state, 0, { type: 'draw' });
  rejected(state, 0, { type: 'discard', card: state.players[1].hand[0] });
  assert.equal(applyAction(state, 0, { type: 'discard', card: top }).ok, true);
  assert.equal(state.turn, 1);
  assert.equal(state.turn_count, 2);
  assert.equal(state.phase, 'draw');
  inventory(state);
});

test('recycling is deterministic after JSON restore and preserves the top discard', () => {
  const state = createGame(['a', 'b'], { seed: 92 });
  state.discard.push(...state.deck);
  state.deck = [];
  const top = state.discard.at(-1);
  const restored = JSON.parse(JSON.stringify(state));
  assert.equal(applyAction(state, 0, { type: 'draw', source: 'deck' }).ok, true);
  assert.equal(applyAction(restored, 0, { type: 'draw', source: 'deck' }).ok, true);
  assert.deepEqual(restored, state);
  assert.deepEqual(state.discard, [top]);
  inventory(state);
  // With only a visible discard left, drawing the empty deck fails atomically.
  const limited = createGame(['a', 'b'], { seed: 1 });
  limited.players[1].hand.push(...limited.deck); limited.deck = [];
  rejected(limited, 0, { type: 'draw' }, /vide/);
  limited.discard = [];
  rejected(limited, 0, { type: 'draw', source: 'discard' }, /vide/);
});

test('Tri uses two physical copies, hidden tris, and wins after discard with 6/12 cards', () => {
  assert.equal(triGroups(['0:H:7','1:H:7','0:C:7']).length, 1);
  assert.equal(triGroups(['0:H:7','0:H:7','0:C:7']).length, 0);
  assert.equal(triGroups(['0:H:7','0:H:8','0:H:9']).length, 0);
  assert.equal(triGroups(['0:H:7','J:0','0:C:7']).length, 0);
  const sixSameRank = ['0:H:7','1:H:7','0:C:7','1:C:7','0:D:7','0:S:7'];
  assert.equal(triGroups(sixSameRank).length, 2);
  for (const size of [6, 12]) {
    const hand = ['0:H:7','1:H:7','0:C:7','0:S:8','0:C:8','0:D:2'];
    if (size === 12) hand.push('0:S:9','0:C:9','0:D:9','0:H:1','0:S:3','0:D:4');
    const state = rig(hand, { triCards: size, phase: 'draw', draw: '0:D:8' });
    assert.equal(state.players[0].hand.length, size);
    assert.equal(state.tri_goal, size === 6 ? 2 : 3);
    assert.equal(viewFor(state, 1).winning_tris.length, 0);
    assert.equal(applyAction(state, 0, { type: 'draw' }).ok, true);
    assert.equal(state.winner, -1);
    assert.equal(state.players[0].hand.length, size + 1);
    rejected(state, 0, { type: 'meld', cards: hand.slice(0, 3) }, /main/);
    rejected(state, 0, { type: 'extend', cards: hand.slice(0, 3) }, /main/);
    inventory(state);
    assert.equal(applyAction(state, 0, { type: 'discard', card: '0:D:2' }).ok, true);
    assert.equal(state.winner, 0);
    assert.equal(state.players[0].hand.length, size);
    assert.equal(viewFor(state, 1).winning_tris.length, state.tri_goal);
    assert.deepEqual(matchResult(state).winners, [0]);
    assert.equal(state.match.totals[0], 0);
    inventory(state);
    const restored = JSON.parse(JSON.stringify(state));
    assert.equal(validateState(restored), true);
    assert.deepEqual(viewFor(restored, 1), viewFor(state, 1));
  }
});

test('private views contain no deck, other hands, RNG, or reusable references', () => {
  const state = createGame(['a', 'b', 'c'], { seed: 11 });
  const view = viewFor(state, 1);
  assert.deepEqual(view.hand, state.players[1].hand);
  assert.equal(viewFor(state, -1).hand.length, 0);
  for (const forbidden of ['deck','discard','_rng_state']) assert.equal(Object.hasOwn(view, forbidden), false);
  assert.ok(view.players.every(p => !Object.hasOwn(p, 'hand')));
  view.hand[0] = 'tampered'; view.players[0].name = 'tampered'; view.match.totals[0] = 999;
  assert.notEqual(state.players[1].hand[0], 'tampered');
  assert.equal(state.players[0].name, 'a');
  assert.equal(state.match.totals[0], 0);
});

test('forfeit eliminates off-turn/current players, preserves all cards and selects last active', () => {
  const state = createGame(['a','b','c','d'], { seed: 3 });
  assert.equal(forfeitPlayer(state, 1).ok, true);
  assert.equal(state.winner, -1);
  assert.equal(state.turn, 0);
  assert.equal(applyAction(state, 0, { type: 'draw' }).ok, true);
  assert.equal(forfeitPlayer(state, 0).ok, true);
  assert.equal(state.turn, 2);
  assert.equal(state.phase, 'draw');
  rejected(state, 1, { type: 'draw' }, /abandonné/);
  inventory(state);
  const before = clone(state);
  for (const index of [-1, 4, 0.1]) { assert.equal(forfeitPlayer(state, index).ok, false); assert.deepEqual(state, before); }
  assert.equal(forfeitPlayer(state, 1).ok, false);
  assert.deepEqual(state, before);
  assert.equal(forfeitPlayer(state, 3, 'déconnexion prolongée').ok, true);
  assert.equal(state.winner, 2);
  assert.deepEqual(matchResult(state).winners, [2]);
  assert.equal(viewFor(state, 2).match_result.forfeit, true);
  assert.equal(state.match.totals[2], 0);
  inventory(state);
});

test('duel forfeit and telephone host departure terminate the whole match', () => {
  const tri = createGame(['a','b'], { triCards: 12, seed: 3 });
  assert.equal(forfeitPlayer(tri, 0).ok, true);
  assert.deepEqual(matchResult(tri).winners, [1]);
  assert.equal(viewFor(tri, 1).winning_tris.length, 0);
  inventory(tri);
  const state = createGame(['a','b','c','d'], { seed: 3 });
  assert.equal(forfeitPlayer(state, 0, 'hote_abandon', true).ok, true);
  assert.deepEqual(matchResult(state).winners, [1,2,3]);
  assert.ok(state.match.results[0].points.slice(1).every(n => n === 0));
  inventory(state);
});

test('corrupt persisted state is rejected without mutation', () => {
  const good = createGame(['a','b'], { seed: 3 });
  for (const edit of [
    s => s.deck.push(s.deck[0]), s => s.deck[0]='unknown', s => s.turn=9,
    s => s.players[0].hand=[], s => s.variant='other', s => s.match.totals[0]=1,
    s => s.players[0].forfeited=true, s => s.revision=NaN, s => s.last_action={type:'hax',player:0},
    s => s.forfeit_winners=[0], s => s.match.results=[{winner:0,points:[0,0]}],
  ]) {
    const bad = clone(good); edit(bad); const before = clone(bad);
    assert.equal(validateState(bad), false);
    assert.deepEqual(bad, before);
  }
  for (const value of [null, [], 1, {}, {players:[{},{}]}]) assert.equal(validateState(value), false);
  const tri = createGame(['a','b'], { triCards:12, seed:1 });
  tri.tri_goal=4;
  assert.equal(validateState(tri), false);
});

// Optional replay against snapshots exported by the actual Godot rules engine.
// GODOT_PARITY_FILE=/absolute/path.json node --test vercel/tests/engine.test.mjs
if (process.env.GODOT_PARITY_FILE) {
  const fixtures = JSON.parse(readFileSync(process.env.GODOT_PARITY_FILE, 'utf8'));
  test(`Godot meld parity (${fixtures.melds.length} physical combinations)`, () => {
    for (const row of fixtures.melds) assert.deepEqual(validateMeld(row.cards), row.expected, row.cards.join(','));
  });
  test(`Godot action and private-view parity (${fixtures.scenarios.length} scenarios)`, () => {
    for (const scenario of fixtures.scenarios) {
      const state = clone(scenario.initial);
      assert.equal(validateState(state), true, scenario.name);
      for (const step of scenario.steps) {
        const result = step.forfeit ? forfeitPlayer(state, step.index, step.reason, step.finish ?? false) : applyAction(state, step.index, step.action);
        assert.deepEqual(result, step.result, `${scenario.name}: result`);
        assert.deepEqual(state, step.state, `${scenario.name}: state`);
        for (let i = 0; i < state.players.length; i++) assert.deepEqual(viewFor(state, i), step.views[i], `${scenario.name}: private view ${i}`);
        assert.equal(validateState(state), true, `${scenario.name}: state validation`);
      }
    }
  });
}
