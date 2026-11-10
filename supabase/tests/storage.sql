-- Run with a privileged SQL connection. Everything rolls back, including QA data.
begin;
do $$
declare
  v_code text;
  v_one uuid := gen_random_uuid();
  v_two uuid := gen_random_uuid();
  v_room jsonb;
begin
  loop
    v_code := lpad(floor(random()*1000000)::text, 6, '0');
    v_room := jsonb_build_object('code', v_code, 'version', 1, 'players', jsonb_build_array(jsonb_build_object('name','QA SQL')),
      'started', false, 'game', null, 'activity', extract(epoch from clock_timestamp())*1000);
    exit when public.rami_room_create(v_code, v_room) = 'created';
  end loop;
  assert public.rami_room_read(v_code) = v_room, 'private durable read';
  assert public.rami_room_lock(v_code, v_one)->>'status' = 'ok', 'first writer owns lease';
  assert public.rami_room_lock(v_code, v_two)->>'status' = 'busy', 'parallel writer excluded';
  v_room := jsonb_set(v_room, '{version}', '2');
  assert not public.rami_room_commit(v_code, v_two, 1, v_room), 'foreign lease cannot commit';
  update rami_private.rooms set lock_until = statement_timestamp() - interval '1 second' where code = v_code;
  assert public.rami_room_lock(v_code, v_two)->>'status' = 'ok', 'expired lease can be recovered';
  assert not public.rami_room_commit(v_code, v_one, 1, v_room), 'expired writer fenced out';
  perform public.rami_room_release(v_code, v_one);
  assert public.rami_room_lock(v_code, v_one)->>'status' = 'busy', 'old release cannot unlock replacement';
  assert public.rami_room_commit(v_code, v_two, 1, v_room), 'current writer commits atomically';
  assert public.rami_room_read(v_code)->>'version' = '2', 'committed version visible';
  assert public.rami_room_lock(v_code, v_one)->>'status' = 'ok', 'successful commit unlocks';
  assert not public.rami_room_commit(v_code, v_one, 0, jsonb_set(v_room, '{version}', '1')), 'stale version rejected';
  v_room := jsonb_set(jsonb_set(v_room, '{version}', '3'), '{players}', '[]');
  assert public.rami_room_commit(v_code, v_one, 2, v_room), 'empty room deletion committed';
  assert public.rami_room_read(v_code) is null, 'empty room removed';
  assert not has_table_privilege('anon','rami_private.rooms','select'), 'no public card access';
  assert not has_table_privilege('authenticated','rami_private.rooms','select'), 'no user card access';
  assert not has_function_privilege('anon','public.rami_room_read(text)','execute'), 'no anonymous RPC';
end;
$$;

do $$
declare
  v_code text;
  v_token uuid := gen_random_uuid();
  v_alice text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_bob text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_room jsonb;
begin
  assert public.rami_room_wallet_sync(v_alice, '[{"id":"abc","level":1}]') = 560, 'solo reward credited';
  assert public.rami_room_wallet_sync(v_alice, '[{"id":"abc","level":2}]') = 560, 'receipt cannot be credited again';
  assert public.rami_room_wallet_sync(v_bob, '[]') = 500, 'new wallet balance';
  loop
    v_code := lpad(floor(random()*1000000)::text, 6, '0');
    v_room := jsonb_build_object('code', v_code, 'version', 1, 'stake', 200,
      'players', jsonb_build_array(jsonb_build_object('wallet',v_alice)), 'game', null,
      'activity', extract(epoch from clock_timestamp())*1000);
    exit when public.rami_room_create(v_code, v_room) = 'created';
  end loop;
  v_room := v_room || jsonb_build_object('version', 2,
    'players', v_room->'players' || jsonb_build_array(jsonb_build_object('wallet',v_bob)),
    'game', jsonb_build_object('session_id','duel'));
  assert public.rami_room_lock(v_code, v_token)->>'status' = 'ok';
  assert public.rami_room_commit(v_code, v_token, 1, v_room), 'match and stake reserve together';
  assert public.rami_room_wallet_sync(v_alice, '[]') = 360;
  assert public.rami_room_wallet_sync(v_bob, '[]') = 300;

  v_room := jsonb_set(jsonb_set(v_room, '{version}', '3'), '{game,stake_result}', '{"winner":0}');
  assert public.rami_room_lock(v_code, v_token)->>'status' = 'ok';
  assert public.rami_room_commit(v_code, v_token, 2, v_room), 'winner gets the entire pot';
  assert public.rami_room_wallet_sync(v_alice, '[]') = 760;
  assert public.rami_room_wallet_sync(v_bob, '[]') = 300;
  assert not public.rami_room_commit(v_code, v_token, 2, v_room), 'duplicate result is fenced';
  assert public.rami_room_wallet_sync(v_alice, '[]') = 760;

  assert public.rami_room_lock(v_code, v_token)->>'status' = 'ok';
  v_room := v_room || '{"version":4,"stake":500,"game":{"session_id":"another"}}';
  begin
    perform public.rami_room_commit(v_code, v_token, 3, v_room);
    raise exception 'Expected insufficient funds';
  exception when sqlstate 'RM001' then null;
  end;
  assert public.rami_room_read(v_code)->>'version' = '3', 'failed debit cannot start a match';
  assert public.rami_room_wallet_sync(v_alice, '[]') = 760, 'failed debit cannot charge other players';

  v_room := v_room || '{"stake":100}';
  assert public.rami_room_commit(v_code, v_token, 3, v_room);
  v_room := v_room || '{"version":5,"game":{"session_id":"another","stake_result":{"winner":null}}}';
  assert public.rami_room_lock(v_code, v_token)->>'status' = 'ok';
  assert public.rami_room_commit(v_code, v_token, 4, v_room), 'tie refunds both stakes';
  assert public.rami_room_wallet_sync(v_alice, '[]') = 760;
  assert public.rami_room_wallet_sync(v_bob, '[]') = 300;

  v_room := v_room || '{"version":6,"game":{"session_id":"expired"}}';
  assert public.rami_room_lock(v_code, v_token)->>'status' = 'ok';
  assert public.rami_room_commit(v_code, v_token, 5, v_room);
  update rami_private.rooms set expires_at = statement_timestamp() - interval '1 second' where code = v_code;
  assert public.rami_room_wallet_sync(v_bob, '[]') = 300, 'expired match refunds its reservations';
  assert public.rami_room_wallet_sync(v_alice, '[]') = 760;
  assert not has_table_privilege('authenticated','rami_private.wallets','select');
  assert not has_function_privilege('anon','public.rami_room_wallet_sync(text,jsonb)','execute');
end;
$$;
rollback;
