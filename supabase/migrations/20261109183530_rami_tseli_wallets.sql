-- The wallet bearer never reaches Postgres. Only its SHA-256 digest is stored.
create table rami_private.wallets (
  wallet_key text primary key check (wallet_key ~ '^[0-9a-f]{64}$'),
  balance bigint not null default 500 check (balance >= 0)
);
create table rami_private.solo_receipts (
  wallet_key text not null references rami_private.wallets(wallet_key),
  match_id text not null check (match_id ~ '^[0-9a-f]{2,16}$'),
  level integer not null check (level between 0 and 2),
  primary key (wallet_key, match_id)
);
alter table rami_private.wallets enable row level security;
alter table rami_private.solo_receipts enable row level security;
revoke all on rami_private.wallets, rami_private.solo_receipts from public, anon, authenticated;
grant select, insert, update on rami_private.wallets to service_role;
grant select, insert on rami_private.solo_receipts to service_role;

create function public.rami_room_wallet_sync(p_key text, p_wins jsonb)
returns bigint language plpgsql security invoker set search_path = '' as $$
declare
  v_balance bigint;
  v_credit bigint;
begin
  if p_key is null or p_key !~ '^[0-9a-f]{64}$'
    or jsonb_typeof(p_wins) is distinct from 'array'
    or jsonb_array_length(p_wins) > 24 then
    raise exception 'Invalid wallet request';
  end if;

  -- Release reservations from an expired room even if nobody creates a new one.
  delete from rami_private.rooms
  where expires_at <= statement_timestamp() and state->'players' @> jsonb_build_array(jsonb_build_object('wallet', p_key));

  insert into rami_private.wallets(wallet_key) values (p_key)
    on conflict (wallet_key) do nothing;
  if jsonb_array_length(p_wins) = 0 then
    select balance into v_balance from rami_private.wallets where wallet_key = p_key;
    return v_balance;
  end if;

  perform 1 from rami_private.wallets where wallet_key = p_key for update;
  with credited as (
    insert into rami_private.solo_receipts(wallet_key, match_id, level)
      select p_key, win.id, win.level
      from jsonb_to_recordset(p_wins) as win(id text, level integer)
      on conflict (wallet_key, match_id) do nothing
      returning level
  )
  select coalesce(sum((array[25, 60, 120])[level + 1]), 0) into v_credit from credited;

  update rami_private.wallets set balance = balance + v_credit where wallet_key = p_key returning balance into v_balance;
  return v_balance;
end;
$$;
revoke all on function public.rami_room_wallet_sync(text, jsonb) from public, anon, authenticated;
grant execute on function public.rami_room_wallet_sync(text, jsonb) to service_role;

-- A room commit and its stake movements succeed or roll back together.
-- Its existing lease and version fence also guard retries of a wallet movement.
create function rami_private.move_room_stakes()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare
  v_old_stake integer := coalesce((old.state->>'stake')::integer, 0);
  v_new_stake integer := 0;
  v_old_match text := old.state #>> '{game,session_id}';
  v_new_match text;
  v_result jsonb;
  v_old_keys text[] := '{}';
  v_new_keys text[] := '{}';
  v_winner integer;
  v_debited integer;
begin
  if tg_op = 'UPDATE' then
    v_new_stake := coalesce((new.state->>'stake')::integer, 0);
    v_new_match := new.state #>> '{game,session_id}';
    v_result := new.state #> '{game,stake_result}';
  end if;

  if v_old_stake > 0 and v_old_match is not null
    and old.state #> '{game,stake_result}' is null
    and (v_new_match is distinct from v_old_match or v_result is not null) then
    select array_agg(player->>'wallet' order by seat) into v_old_keys
      from jsonb_array_elements(old.state->'players') with ordinality as p(player, seat);
    if v_new_match = v_old_match then v_winner := (v_result->>'winner')::integer; end if;
  end if;
  if v_new_stake > 0 and v_new_match is not null and v_new_match is distinct from v_old_match then
    select array_agg(player->>'wallet' order by seat) into v_new_keys
      from jsonb_array_elements(new.state->'players') with ordinality as p(player, seat);
  end if;

  if cardinality(v_old_keys) + cardinality(v_new_keys) > 0 then
    -- A wallet may appear in several rooms. Lock rows in one consistent order.
    perform 1 from rami_private.wallets
      where wallet_key = any(v_old_keys || v_new_keys) order by wallet_key for update;
  end if;

  if v_winner is not null then
    update rami_private.wallets set balance = balance + v_old_stake * cardinality(v_old_keys)
      where wallet_key = v_old_keys[v_winner + 1];
  elsif cardinality(v_old_keys) > 0 then
    -- Tied first place or a room closed before a result.
    update rami_private.wallets set balance = balance + v_old_stake where wallet_key = any(v_old_keys);
  end if;

  if cardinality(v_new_keys) > 0 then
    update rami_private.wallets set balance = balance - v_new_stake
      where wallet_key = any(v_new_keys) and balance >= v_new_stake;
    get diagnostics v_debited = row_count;
    if v_debited <> cardinality(v_new_keys) then
      raise exception using errcode = 'RM001', message = 'Insufficient Tselis';
    end if;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
revoke all on function rami_private.move_room_stakes() from public, anon, authenticated;
grant execute on function rami_private.move_room_stakes() to service_role;
create trigger move_room_stakes
  before update of state or delete on rami_private.rooms
  for each row execute function rami_private.move_room_stakes();
