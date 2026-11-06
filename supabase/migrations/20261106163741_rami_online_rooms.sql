-- Only the Edge Function's service role can read raw hands or session tokens.
create schema if not exists rami_private;
revoke all on schema rami_private from public, anon, authenticated;
grant usage on schema rami_private to service_role;

create table rami_private.rooms (
  code text primary key check (code ~ '^[0-9]{6}$'),
  state jsonb not null check (jsonb_typeof(state) = 'object'),
  expires_at timestamptz not null,
  lock_token uuid,
  lock_until timestamptz
);
create index rooms_expiration on rami_private.rooms (expires_at);
alter table rami_private.rooms enable row level security;
revoke all on rami_private.rooms from public, anon, authenticated;
grant select, insert, update, delete on rami_private.rooms to service_role;

create function public.rami_room_read(p_code text)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select state from rami_private.rooms
  where code = p_code and expires_at > statement_timestamp();
$$;

create function public.rami_room_create(p_code text, p_room jsonb)
returns text language plpgsql security invoker set search_path = '' as $$
begin
  -- Serialize the small global capacity check; individual turns lock one room.
  perform pg_catalog.pg_advisory_xact_lock(724183606);
  delete from rami_private.rooms where expires_at <= statement_timestamp();
  if (select count(*) from rami_private.rooms) >= 64 then return 'full'; end if;
  if p_room->>'code' is distinct from p_code
    or (p_room->>'version')::bigint <> 1
    or jsonb_array_length(p_room->'players') <> 1 then
    raise exception 'Invalid initial room';
  end if;
  insert into rami_private.rooms(code, state, expires_at)
  values (p_code, p_room, statement_timestamp() + interval '24 hours')
  on conflict (code) do nothing;
  if found then return 'created'; end if;
  return 'collision';
end;
$$;

create function public.rami_room_lock(p_code text, p_lock uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_room jsonb;
begin
  update rami_private.rooms set lock_token = p_lock,
    lock_until = statement_timestamp() + interval '8 seconds'
  where code = p_code and expires_at > statement_timestamp()
    and (lock_token is null or lock_until <= statement_timestamp())
  returning state into v_room;
  if found then return jsonb_build_object('status', 'ok', 'room', v_room); end if;
  if exists (select 1 from rami_private.rooms where code = p_code and expires_at > statement_timestamp())
    then return jsonb_build_object('status', 'busy'); end if;
  return jsonb_build_object('status', 'missing');
end;
$$;

create function public.rami_room_commit(p_code text, p_lock uuid, p_version bigint, p_room jsonb)
returns boolean language plpgsql security invoker set search_path = '' as $$
begin
  if p_room->>'code' is distinct from p_code
    or (p_room->>'version')::bigint <> p_version + 1
    or jsonb_typeof(p_room->'players') is distinct from 'array' then
    raise exception 'Invalid room version';
  end if;
  -- The lease token AND version fence an expired writer after another worker
  -- has taken over. Commit and unlock are a single database transaction.
  if jsonb_array_length(p_room->'players') = 0 then
    delete from rami_private.rooms where code = p_code and lock_token = p_lock
      and lock_until > statement_timestamp() and (state->>'version')::bigint = p_version;
  else
    update rami_private.rooms set state = p_room,
      expires_at = to_timestamp((p_room->>'activity')::double precision / 1000) + interval '24 hours',
      lock_token = null, lock_until = null
    where code = p_code and lock_token = p_lock and lock_until > statement_timestamp()
      and (state->>'version')::bigint = p_version;
  end if;
  return found;
end;
$$;

create function public.rami_room_release(p_code text, p_lock uuid)
returns void language sql security invoker set search_path = '' as $$
  update rami_private.rooms set lock_token = null, lock_until = null
  where code = p_code and lock_token = p_lock;
$$;

revoke all on function public.rami_room_read(text) from public, anon, authenticated;
revoke all on function public.rami_room_create(text, jsonb) from public, anon, authenticated;
revoke all on function public.rami_room_lock(text, uuid) from public, anon, authenticated;
revoke all on function public.rami_room_commit(text, uuid, bigint, jsonb) from public, anon, authenticated;
revoke all on function public.rami_room_release(text, uuid) from public, anon, authenticated;
grant execute on function public.rami_room_read(text) to service_role;
grant execute on function public.rami_room_create(text, jsonb) to service_role;
grant execute on function public.rami_room_lock(text, uuid) to service_role;
grant execute on function public.rami_room_commit(text, uuid, bigint, jsonb) to service_role;
grant execute on function public.rami_room_release(text, uuid) to service_role;
