/** Authoritative online rules, ported from scripts/rami_engine.gd.
 * The state is plain JSON. Only viewFor may be sent to a phone: raw state
 * contains the deck, opponents' hands and deterministic shuffle state.
 */
import { randomBytes } from 'node:crypto';

export const SUITS = Object.freeze(['S', 'H', 'D', 'C']);
const LABELS = ['', 'A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'V', 'D', 'R'];
const clone = value => structuredClone(value);
const ok = () => ({ ok: true, error: '' });
const fail = error => ({ ok: false, error });
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const integer = (value, min, max) => Number.isSafeInteger(value) && value >= min && value <= max;
const unique = values => new Set(values).size === values.length;
const get = (obj, key, fallback) => Object.hasOwn(obj, key) ? obj[key] : fallback;

export function cardInfo(id) {
  if (typeof id !== 'string') return null;
  if (/^J:[0-3]$/.test(id)) return { id, rank: 0, suit: 'J', joker: true, points: 20, label: 'Joker' };
  const match = /^([01]):([SHDC]):([1-9]|1[0-3])$/.exec(id);
  if (!match) return null;
  const rank = Number(match[3]);
  return { id, rank, suit: match[2], joker: false, points: rank === 1 ? 11 : Math.min(rank, 10), label: LABELS[rank] };
}

export function physicalDeck(includeJokers = true) {
  const cards = [];
  for (let copy = 0; copy < 2; copy++) for (const suit of SUITS) for (let rank = 1; rank <= 13; rank++) cards.push(`${copy}:${suit}:${rank}`);
  if (includeJokers) for (let j = 0; j < 4; j++) cards.push(`J:${j}`);
  return cards;
}

// A small explicit PRNG makes subsequent deck recycling reproducible after a
// Redis restore. It is not used for authentication/session tokens.
function nextRandom(state) {
  state._rng_state = (state._rng_state + 0x6D2B79F5) >>> 0;
  let n = state._rng_state;
  n = Math.imul(n ^ n >>> 15, n | 1);
  n ^= n + Math.imul(n ^ n >>> 7, n | 61);
  return ((n ^ n >>> 14) >>> 0) / 4294967296;
}
function shuffle(cards, state) {
  for (let i = cards.length - 1; i > 0; i--) {
    const j = Math.floor(nextRandom(state) * (i + 1));
    [cards[i], cards[j]] = [cards[j], cards[i]];
  }
}

export function createGame(names, { triCards = 0, seed = 0 } = {}) {
  if (!Array.isArray(names) || names.length < 2 || names.length > 4) throw new TypeError('Une partie accueille de 2 à 4 joueurs.');
  if (![0, 6, 12].includes(triCards) || (triCards > 0 && names.length !== 2)) throw new TypeError('Le Tri se joue en duel, avec 6 ou 12 cartes par joueur.');
  if (!Number.isSafeInteger(seed)) throw new TypeError('Graine invalide.');
  const state = {
    players: names.map((name, i) => ({ name: Array.from(String(name).trim()).slice(0, 24).join('') || `Joueur ${i + 1}`, hand: [], opened: false, forfeited: false })),
    deck: physicalDeck(triCards === 0), discard: [], melds: [], turn: 0, phase: 'draw', winner: -1,
    log: '', turn_count: 1, revision: 0, last_action: {},
    session_id: seed ? `seed-${seed}` : randomBytes(16).toString('hex'),
    win_by_forfeit: false, end_reason: '', forfeit_winners: [],
    match: { round: 1, length: 1, totals: names.map(() => 0), results: [] },
    _rng_state: seed ? seed >>> 0 : randomBytes(4).readUInt32LE(),
  };
  shuffle(state.deck, state);
  const size = triCards || 13;
  for (let n = 0; n < size; n++) for (const player of state.players) player.hand.push(state.deck.pop());
  state.discard.push(state.deck.pop());
  state.log = `${state.players[0].name} commence : piochez une carte.`;
  if (triCards) {
    Object.assign(state, { variant: 'tri', tri_hand_size: triCards, tri_goal: triCards === 6 ? 2 : 3 });
    state.log = 'Tri : gardez vos combinaisons en main. Piochez, puis défaussez.';
  }
  return state;
}

export function validateMeld(cards) {
  if (!Array.isArray(cards) || cards.length < 3 || cards.length > 13) return fail('Une combinaison contient au moins 3 cartes.');
  const naturals = [], jokers = [], seen = new Set();
  for (const id of cards) {
    if (typeof id !== 'string' || seen.has(id)) return fail('Une carte ne peut être utilisée deux fois.');
    seen.add(id);
    const info = cardInfo(id);
    if (!info) return fail('Carte inconnue.');
    if (info.joker) jokers.push(id); else naturals.push(info);
  }
  if (jokers.length * 2 > cards.length) return fail('Une combinaison doit contenir au moins autant de cartes naturelles que de jokers.');
  const sameRank = naturals.every(info => info.rank === naturals[0].rank);
  const sameSuit = naturals.every(info => info.suit === naturals[0].suit);
  if (sameRank && cards.length <= 4 && unique(naturals.map(info => info.suit))) {
    return { ...ok(), cards: cards.slice(), points: cards.length * naturals[0].points, type: 'set' };
  }
  if (!sameSuit || !unique(naturals.map(info => info.rank))) return fail("Formez un brelan/carré de couleurs différentes ou une suite d'une même couleur.");
  let best = null;
  for (const highAce of [false, true]) {
    const byRank = new Map(naturals.map(info => [highAce && info.rank === 1 ? 14 : info.rank, info.id]));
    const lower = highAce ? 2 : 1, upper = highAce ? 14 : 13;
    for (let first = lower; first <= upper - cards.length + 1; first++) {
      const last = first + cards.length - 1;
      if ([...byRank.keys()].some(rank => rank < first || rank > last)) continue;
      const ordered = []; let jokerIndex = 0, points = 0;
      for (let rank = first; rank <= last; rank++) {
        points += rank === 14 ? 11 : Math.min(rank, 10);
        ordered.push(byRank.has(rank) ? byRank.get(rank) : jokers[jokerIndex++]);
      }
      if (!best || points > best.points) best = { ...ok(), cards: ordered, points, type: 'run' };
    }
  }
  return best || fail("La suite doit être consécutive ; l'as peut être avant le 2 ou après le roi.");
}

function rankTris(cards) {
  let best = [];
  for (let a = 0; a < cards.length - 2; a++) for (let b = a + 1; b < cards.length - 1; b++) for (let c = b + 1; c < cards.length; c++) {
    if (cardInfo(cards[a]).suit === cardInfo(cards[b]).suit && cardInfo(cards[b]).suit === cardInfo(cards[c]).suit) continue;
    const group = [cards[a], cards[b], cards[c]];
    const found = [group, ...rankTris(cards.filter(id => !group.includes(id)))];
    if (found.length > best.length) best = found;
    if (best.length === Math.floor(cards.length / 3)) return best;
  }
  return best;
}
export function triGroups(cards) {
  if (!Array.isArray(cards)) return [];
  const ranks = new Map();
  for (const id of cards) {
    if (typeof id !== 'string') return [];
    const info = cardInfo(id);
    if (!info || info.joker) continue;
    if (!ranks.has(info.rank)) ranks.set(info.rank, []);
    const bucket = ranks.get(info.rank);
    if (bucket.includes(id)) return [];
    bucket.push(id);
  }
  return [...ranks.values()].flatMap(rankTris);
}

function nextActive(state, after) {
  for (let offset = 1; offset <= state.players.length; offset++) {
    const index = (after + offset) % state.players.length;
    if (!state.players[index].forfeited) return index;
  }
  return after;
}

function recordRound(state) {
  const data = state.match;
  if (data.results.length >= data.round) return;
  const points = state.players.map((player, i) => {
    if ((state.win_by_forfeit && state.forfeit_winners.includes(i)) || (state.variant === 'tri' && i === state.winner)) return 0;
    return player.hand.reduce((sum, id) => sum + cardInfo(id).points, 0);
  });
  data.totals = data.totals.map((total, i) => total + points[i]);
  const result = { winner: state.winner, points };
  if (state.win_by_forfeit) Object.assign(result, { forfeit: true, reason: state.end_reason, winners: state.forfeit_winners.slice() });
  data.results.push(result);
}

function draw(state, index, action) {
  if (state.phase !== 'draw') return fail('Vous avez déjà pioché.');
  const source = get(action, 'source', 'deck');
  if (!['deck', 'discard'].includes(source)) return fail('Pioche inconnue.');
  if (source === 'discard' && !state.discard.length) return fail('La défausse est vide.');
  if (source === 'deck' && !state.deck.length && state.discard.length < 2) return fail('La pioche est vide. Prenez la défausse.');
  if (source === 'deck' && !state.deck.length) {
    const top = state.discard.pop();
    state.deck = state.discard.slice();
    state.discard = [top];
    shuffle(state.deck, state);
  }
  state.players[index].hand.push((source === 'deck' ? state.deck : state.discard).pop());
  state.phase = 'play';
  state.log = `${state.players[index].name} a pioché. Posez vos combinaisons ou défaussez une carte.`;
  return ok();
}
function meld(state, index, action) {
  const groups = get(action, 'groups', [get(action, 'cards', [])]);
  if (!Array.isArray(groups) || !groups.length || groups.length > 4) return fail('Sélectionnez une ou plusieurs combinaisons.');
  const used = [], checked = []; let points = 0;
  for (const cards of groups) {
    if (!Array.isArray(cards)) return fail('Combinaison invalide.');
    for (const id of cards) {
      if (typeof id !== 'string' || !state.players[index].hand.includes(id) || used.includes(id)) return fail('Ces cartes ne sont pas toutes disponibles dans votre main.');
      used.push(id);
    }
    const result = validateMeld(cards);
    if (!result.ok) return fail(result.error);
    points += result.points;
    checked.push(result);
  }
  if (used.length >= state.players[index].hand.length) return fail('Gardez une carte pour la défausse finale.');
  if (!state.players[index].opened && points < 30) return fail('La première pose doit totaliser au moins 30 points.');
  for (const result of checked) state.melds.push({ cards: result.cards, owner: index, type: result.type });
  const usedSet = new Set(used);
  state.players[index].hand = state.players[index].hand.filter(id => !usedSet.has(id));
  state.players[index].opened = true;
  state.log = `${state.players[index].name} pose ${used.length} carte${used.length > 1 ? 's' : ''} (${points} points).`;
  return ok();
}
function extend(state, index, action) {
  if (!state.players[index].opened) return fail("Ouvrez d'abord avec au moins 30 points.");
  const meldIndex = action.meld ?? -1;
  if (!integer(meldIndex, 0, state.melds.length - 1)) return fail('Combinaison inconnue.');
  const cards = action.cards ?? [];
  if (!Array.isArray(cards) || !cards.length) return fail('Sélectionnez les cartes à ajouter.');
  const used = [];
  for (const id of cards) {
    if (typeof id !== 'string' || !state.players[index].hand.includes(id) || used.includes(id)) return fail('Ces cartes ne sont pas disponibles.');
    used.push(id);
  }
  if (used.length >= state.players[index].hand.length) return fail('Gardez une carte pour la défausse finale.');
  const result = validateMeld([...state.melds[meldIndex].cards, ...cards]);
  if (!result.ok) return fail('Ces cartes ne prolongent pas cette combinaison.');
  state.melds[meldIndex].cards = result.cards;
  const usedSet = new Set(used);
  state.players[index].hand = state.players[index].hand.filter(id => !usedSet.has(id));
  state.log = `${state.players[index].name} complète une combinaison.`;
  return ok();
}
function discard(state, index, action) {
  const id = action.card ?? '';
  if (typeof id !== 'string' || !state.players[index].hand.includes(id)) return fail('Sélectionnez une carte de votre main à défausser.');
  state.players[index].hand.splice(state.players[index].hand.indexOf(id), 1);
  state.discard.push(id);
  if (!state.players[index].hand.length || (state.variant === 'tri' && triGroups(state.players[index].hand).length >= state.tri_goal)) {
    state.winner = index;
    state.log = `${state.players[index].name} remporte la manche !`;
  } else {
    state.turn = nextActive(state, index);
    state.phase = 'draw';
    state.turn_count++;
    state.log = `Au tour de ${state.players[state.turn].name} : piochez une carte.`;
  }
  return ok();
}

export function applyAction(state, index, action) {
  if (!object(state) || !Array.isArray(state.players) || !state.players.length) return fail('Aucune partie en cours.');
  if (!integer(index, 0, state.players.length - 1)) return fail('Joueur inconnu.');
  if (state.winner >= 0) return fail('La manche est terminée.');
  if (state.players[index].forfeited) return fail('Vous avez abandonné cette partie.');
  if (state.turn !== index) return fail("Ce n'est pas votre tour.");
  if (!object(action) || typeof action.type !== 'string') return fail('Action inconnue.');
  const kind = action.type;
  let result;
  if (kind === 'draw') result = draw(state, index, action);
  else {
    if (state.variant === 'tri' && ['meld', 'extend'].includes(kind)) return fail('Au Tri, les combinaisons restent en main jusqu’à la victoire.');
    if (!['meld', 'extend', 'discard'].includes(kind)) return fail('Action inconnue.');
    if (state.phase !== 'play') return fail("Piochez d'abord une carte.");
    result = { meld, extend, discard }[kind](state, index, action);
  }
  if (result.ok) {
    state.revision++;
    state.last_action = { type: kind, player: index, source: String(action.source ?? 'deck') };
    if (state.winner >= 0) recordRound(state);
  }
  return result;
}

export function forfeitPlayer(state, index, reason = 'abandon', finishMatch = false) {
  if (!object(state) || !Array.isArray(state.players) || !state.players.length) return fail('Aucune partie en cours.');
  if (!integer(index, 0, state.players.length - 1)) return fail('Joueur inconnu.');
  if (state.winner >= 0) return fail('La manche est déjà terminée.');
  if (state.players[index].forfeited) return fail('Ce joueur a déjà abandonné.');
  if (typeof reason !== 'string' || typeof finishMatch !== 'boolean') return fail('Abandon incorrect.');
  state.players[index].forfeited = true;
  const remaining = state.players.flatMap((p, i) => p.forfeited ? [] : [i]);
  state.revision++;
  state.last_action = { type: 'forfeit', player: index, reason };
  if (remaining.length === 1 || finishMatch) {
    state.winner = remaining[0];
    state.win_by_forfeit = true;
    state.end_reason = reason || 'abandon';
    state.forfeit_winners = remaining;
    state.log = remaining.length === 1 ? `${state.players[index].name} abandonne. ${state.players[state.winner].name} remporte le match par forfait.` : `${state.players[index].name} abandonne. Les autres joueurs gagnent par forfait.`;
    recordRound(state);
  } else {
    if (state.turn === index) {
      state.turn = nextActive(state, index);
      state.phase = 'draw';
      state.turn_count++;
    }
    state.log = `${state.players[index].name} abandonne ; les autres joueurs continuent.`;
  }
  return ok();
}

export function matchResult(state) {
  const result = { finished: false, winners: [], forfeit: false, reason: '', round_finished: false, round_winner: -1 };
  if (!object(state) || !Array.isArray(state.players)) return result;
  result.round_finished = state.winner >= 0;
  result.round_winner = state.winner;
  if (state.win_by_forfeit) return { ...result, finished: true, forfeit: true, reason: state.end_reason || 'abandon', winners: state.forfeit_winners.slice() };
  if (!result.round_finished || state.match.round < state.match.length) return result;
  result.finished = true;
  let best = Infinity;
  state.players.forEach((player, i) => {
    if (player.forfeited) return;
    const total = state.match.totals[i] ?? 0;
    if (total < best) { best = total; result.winners = [i]; }
    else if (total === best) result.winners.push(i);
  });
  return result;
}
export function viewFor(state, index) {
  if (!object(state) || !Array.isArray(state.players)) return {};
  return {
    players: state.players.map(player => ({ name: player.name, count: player.hand.length, opened: player.opened, forfeited: Boolean(player.forfeited) })),
    hand: integer(index, 0, state.players.length - 1) ? state.players[index].hand.slice() : [],
    deck_count: state.deck.length, discard_top: state.discard.at(-1) ?? '', melds: clone(state.melds),
    turn: state.turn, phase: state.phase, winner: state.winner, log: state.log, turn_count: state.turn_count,
    revision: state.revision ?? 0, last_action: clone(state.last_action ?? {}), session_id: state.session_id ?? '',
    match: clone(state.match), forfeited: state.players.flatMap((p, i) => p.forfeited ? [i] : []),
    end_reason: state.end_reason ?? '', win_by_forfeit: Boolean(state.win_by_forfeit), match_result: matchResult(state),
    variant: state.variant ?? 'rami', tri_hand_size: state.tri_hand_size ?? 0, tri_goal: state.tri_goal ?? 0,
    winning_tris: state.variant === 'tri' && state.winner >= 0 && !state.win_by_forfeit ? triGroups(state.players[state.winner].hand).slice(0, state.tri_goal) : [],
  };
}

/** Validate persisted server state without modifying it or trusting prototypes. */
export function validateState(state) {
  try {
    if (!object(state) || !Array.isArray(state.players) || !integer(state.players.length, 2, 4)) return false;
    if (![undefined, 'rami', 'tri'].includes(state.variant)) return false;
    const tri = state.variant === 'tri';
    for (const field of ['deck', 'discard', 'melds']) if (!Array.isArray(state[field])) return false;
    const cards = [...state.deck, ...state.discard];
    if (!integer(state.turn, 0, state.players.length - 1) || !integer(state.winner, -1, state.players.length - 1)) return false;
    if (!integer(state.revision, 0, 1e9) || !integer(state.turn_count, 1, 1e9) || !['draw', 'play'].includes(state.phase)) return false;
    if (typeof state.log !== 'string' || typeof state.session_id !== 'string' || !state.session_id) return false;
    if (!object(state.last_action) || typeof state.win_by_forfeit !== 'boolean' || typeof state.end_reason !== 'string') return false;
    if (!Array.isArray(state.forfeit_winners) || !unique(state.forfeit_winners)) return false;
    if (state._rng_state !== undefined && !integer(state._rng_state, 0, 0xffffffff)) return false;
    for (let i = 0; i < state.players.length; i++) {
      const p = state.players[i];
      if (!object(p) || !Array.isArray(p.hand) || typeof p.name !== 'string' || typeof p.opened !== 'boolean' || typeof p.forfeited !== 'boolean') return false;
      cards.push(...p.hand);
      if (tri) {
        const expected = state.tri_hand_size + (i === state.turn && state.phase === 'play' && state.winner === -1 ? 1 : 0);
        if (p.opened || (!state.win_by_forfeit && p.hand.length !== expected)) return false;
      }
    }
    for (const group of state.melds) {
      if (!object(group) || !Array.isArray(group.cards) || !integer(group.owner, 0, state.players.length - 1) || !validateMeld(group.cards).ok) return false;
      cards.push(...group.cards);
    }
    if (cards.length !== (tri ? 104 : 108) || !unique(cards) || cards.some(id => !cardInfo(id) || (tri && cardInfo(id).joker))) return false;
    if (tri && (state.players.length !== 2 || ![6, 12].includes(state.tri_hand_size) || state.tri_goal !== (state.tri_hand_size === 6 ? 2 : 3) || state.melds.length)) return false;
    if (state.forfeit_winners.some(i => !integer(i, 0, state.players.length - 1) || state.players[i].forfeited)) return false;
    if (state.win_by_forfeit) {
      if (state.winner < 0 || !state.forfeit_winners.includes(state.winner) || !state.end_reason || !state.players.some(p => p.forfeited)) return false;
      if (state.players.some((p, i) => !p.forfeited && !state.forfeit_winners.includes(i))) return false;
    } else {
      if (state.forfeit_winners.length) return false;
      if (tri) { if (state.winner >= 0 && triGroups(state.players[state.winner].hand).length < state.tri_goal) return false; }
      else if (state.players.some((p, i) => (p.hand.length === 0) !== (i === state.winner))) return false;
    }
    if ((state.winner >= 0 && state.players[state.winner].forfeited) || (state.winner < 0 && state.players[state.turn].forfeited)) return false;
    if (Object.keys(state.last_action).length && (!integer(state.last_action.player, 0, state.players.length - 1) || !['draw', 'meld', 'extend', 'discard', 'forfeit'].includes(state.last_action.type))) return false;
    const data = state.match;
    // Internet rooms currently play one round, as does the Godot dedicated server.
    if (!object(data) || data.round !== 1 || data.length !== 1 || !Array.isArray(data.totals) || data.totals.length !== state.players.length || !Array.isArray(data.results)) return false;
    if (data.results.length !== (state.winner < 0 ? 0 : 1)) return false;
    const sums = state.players.map(() => 0);
    for (const row of data.results) {
      if (!object(row) || !integer(row.winner, 0, sums.length - 1) || !Array.isArray(row.points) || row.points.length !== sums.length) return false;
      for (let i = 0; i < sums.length; i++) { if (!integer(row.points[i], 0, 2000)) return false; sums[i] += row.points[i]; }
      if (row.points[row.winner] !== 0) return false;
    }
    if (data.totals.some((n, i) => !integer(n, 0, 10000) || n !== sums[i])) return false;
    if (state.winner >= 0 && data.results.at(-1).winner !== state.winner) return false;
    return true;
  } catch { return false; }
}
