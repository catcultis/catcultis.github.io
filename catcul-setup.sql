-- CATCUL / 001 — authenticated chat
-- Run this entire file in YOUR Supabase SQL Editor as the project administrator.
-- This file has NOT been executed against your external project by the assistant.
-- Adds a dedicated catcul schema, private Storage bucket and namespaced policies.
-- No existing application tables are dropped. Safe to re-run for this version.
-- After running: add catcul to Project Settings > Data API > Exposed schemas.
-- Never use a service_role/secret key in the HTML. Keep the public publishable key.

begin;

create schema if not exists catcul;
revoke all on schema catcul from public, anon;
grant usage on schema catcul to authenticated, service_role;
-- New functions must not be executable by PUBLIC by default.
alter default privileges in schema catcul revoke execute on functions from public;
alter default privileges in schema catcul revoke all on tables from anon, authenticated;

create table if not exists catcul.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 28),
  color text not null default '#dcebbf' check (color in ('#dcebbf','#f0dbc4','#d8e5ef','#e6d9ed','#f0e5b7','#cedfd0')),
  created_at timestamptz not null default now()
);
create table if not exists catcul.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 1 and 40),
  created_by uuid references catcul.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists catcul.room_members (
  room_id uuid not null references catcul.rooms(id) on delete cascade,
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('owner','member')),
  joined_at timestamptz not null default now(),
  last_read_at timestamptz,
  primary key (room_id, user_id)
);
create index if not exists catcul_members_by_user on catcul.room_members(user_id, room_id);
create unique index if not exists catcul_one_owner_per_room on catcul.room_members(room_id) where role = 'owner';

create table if not exists catcul.room_invites (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references catcul.rooms(id) on delete cascade,
  token_hash text not null unique,
  created_by uuid references catcul.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  max_uses integer not null default 50 check (max_uses between 1 and 1000),
  uses integer not null default 0 check (uses >= 0),
  revoked_at timestamptz
);
create index if not exists catcul_invites_by_room on catcul.room_invites(room_id);

create table if not exists catcul.attachments (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references catcul.rooms(id) on delete cascade,
  uploaded_by uuid not null default auth.uid() references catcul.profiles(id),
  object_path text not null unique,
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp','audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav')),
  byte_size integer not null check (byte_size between 1 and 5242880),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (id, room_id),
  check (split_part(object_path,'/',1) = room_id::text and split_part(object_path,'/',2) = uploaded_by::text and split_part(object_path,'/',3) <> '' and array_length(string_to_array(object_path,'/'),1) = 3)
);
create index if not exists catcul_attachments_by_room on catcul.attachments(room_id);

create table if not exists catcul.messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references catcul.rooms(id) on delete cascade,
  sender_id uuid not null default auth.uid() references catcul.profiles(id),
  body text not null default '' check (char_length(body) <= 4000),
  kind text not null default 'text' check (kind in ('text','photo','audio')),
  attachment_id uuid,
  reply_to uuid,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  unique (id, room_id),
  foreign key (attachment_id, room_id) references catcul.attachments(id, room_id),
  foreign key (reply_to, room_id) references catcul.messages(id, room_id),
  check (deleted_at is not null or ((kind = 'text' and char_length(btrim(body)) > 0 and attachment_id is null) or (kind in ('photo','audio') and attachment_id is not null)))
);
create index if not exists catcul_messages_timeline on catcul.messages(room_id, created_at desc, id desc);
create index if not exists catcul_messages_by_sender on catcul.messages(sender_id);
create unique index if not exists catcul_one_message_per_attachment on catcul.messages(attachment_id) where attachment_id is not null;

-- Soft toggles instead of DELETE events: Realtime UPDATE remains RLS-filterable.
create table if not exists catcul.message_reactions (
  room_id uuid not null,
  message_id uuid not null,
  user_id uuid not null default auth.uid() references catcul.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('😊','😂','🥹','😍','😎','🫶','🤍','💚','🔥','✨','👀','🙌','👍','🎉','🐱','🌿','☀️','🌙','💬','💛','😅','😭','🤔','🤝','🫠','🥰','💯','📸','🤗','👋')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji),
  foreign key (message_id, room_id) references catcul.messages(id, room_id) on delete cascade
);
create index if not exists catcul_reactions_by_room on catcul.message_reactions(room_id);
create table if not exists catcul.message_receipts (
  room_id uuid not null,
  message_id uuid not null,
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  received_at timestamptz not null default now(),
  read_at timestamptz,
  primary key (message_id, user_id),
  foreign key (message_id, room_id) references catcul.messages(id, room_id) on delete cascade
);
create index if not exists catcul_receipts_by_room on catcul.message_receipts(room_id);

-- Small, search_path-pinned helpers avoid recursive membership RLS policies.
create or replace function catcul.is_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from catcul.room_members where room_id = p_room_id and user_id = (select auth.uid()));
$$;
create or replace function catcul.shares_room(p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_user_id = (select auth.uid()) or exists (
    select 1 from catcul.room_members a join catcul.room_members b on a.room_id = b.room_id
    where a.user_id = (select auth.uid()) and b.user_id = p_user_id
  );
$$;
create or replace function catcul.topic_allowed(p_topic text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if p_topic !~ '^catcul:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return catcul.is_member(split_part(p_topic, ':', 2)::uuid);
end;
$$;
create or replace function catcul.can_upload_media(p_path text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if array_length(string_to_array(p_path,'/'),1) <> 3 or split_part(p_path,'/',1) !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return split_part(p_path,'/',2) = (select auth.uid())::text
    and catcul.is_member(split_part(p_path,'/',1)::uuid);
end;
$$;
create or replace function catcul.can_read_media(p_path text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from catcul.attachments a
    where a.object_path = p_path and a.deleted_at is null and catcul.is_member(a.room_id));
$$;

create or replace function catcul.ensure_profile()
returns catcul.profiles language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_profile catcul.profiles;
begin
  if v_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  insert into catcul.profiles(id, display_name)
    select v_user, coalesce(nullif(left(btrim(raw_user_meta_data->>'display_name'),28),''),'New friend') from auth.users where id = v_user
    on conflict (id) do nothing;
  select * into strict v_profile from catcul.profiles where id = v_user;
  return v_profile;
end;
$$;
-- App calls ensure_profile after login: no signup trigger is installed on auth.users.

create or replace function catcul.create_room(p_name text)
returns catcul.rooms language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_room catcul.rooms;
begin
  if v_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  perform catcul.ensure_profile();
  -- Serialize per-user creation/join so the room limit cannot race.
  perform 1 from catcul.profiles where id = v_user for update;
  if (select count(*) from catcul.room_members where user_id = v_user) >= 50 then raise exception 'Maximum 50 rooms per account.'; end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 40 then raise exception 'Room names must be 1–40 characters.'; end if;
  insert into catcul.rooms(name,created_by) values(btrim(p_name),v_user) returning * into v_room;
  insert into catcul.room_members(room_id,user_id,role) values(v_room.id,v_user,'owner');
  return v_room;
end;
$$;

create or replace function catcul.create_invite(p_room_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare v_token text;
begin
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode = '42501'; end if;
  perform 1 from catcul.rooms where id = p_room_id for update;
  if (select count(*) from catcul.room_invites where room_id = p_room_id and created_at > now()-interval '1 minute') >= 10 then raise exception 'Please wait a minute before creating another invite.'; end if;
  v_token := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
  insert into catcul.room_invites(room_id,token_hash,created_by)
    values(p_room_id,encode(sha256(convert_to(v_token,'UTF8')),'hex'),auth.uid());
  return v_token;
end;
$$;
create or replace function catcul.join_room(p_token text)
returns catcul.rooms language plpgsql security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); v_invite catcul.room_invites; v_room catcul.rooms;
begin
  if v_user is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'Invalid invitation.'; end if;
  perform catcul.ensure_profile();
  perform 1 from catcul.profiles where id = v_user for update;
  select * into v_invite from catcul.room_invites where token_hash = encode(sha256(convert_to(p_token,'UTF8')),'hex') for update;
  if not found or v_invite.revoked_at is not null or v_invite.expires_at <= now() or v_invite.uses >= v_invite.max_uses then raise exception 'This invitation is invalid, expired, revoked, or full.'; end if;
  if not catcul.is_member(v_invite.room_id) then
    if (select count(*) from catcul.room_members where user_id = v_user) >= 50 then raise exception 'Maximum 50 rooms per account.'; end if;
    insert into catcul.room_members(room_id,user_id) values(v_invite.room_id,v_user);
    update catcul.room_invites set uses = uses+1 where id = v_invite.id;
  end if;
  select * into strict v_room from catcul.rooms where id = v_invite.room_id;
  return v_room;
end;
$$;
create or replace function catcul.revoke_invites(p_room_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from catcul.room_members where room_id=p_room_id and user_id=auth.uid() and role='owner') then raise exception 'Only the room owner can revoke invitations.' using errcode='42501'; end if;
  update catcul.room_invites set revoked_at=now() where room_id=p_room_id and revoked_at is null;
end;
$$;
create or replace function catcul.leave_room(p_room_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_role text; v_next uuid;
begin
  perform 1 from catcul.rooms where id=p_room_id for update;
  select role into v_role from catcul.room_members where room_id=p_room_id and user_id=auth.uid();
  if v_role is null then raise exception 'Room membership required.' using errcode='42501'; end if;
  delete from catcul.room_members where room_id=p_room_id and user_id=auth.uid();
  if v_role='owner' then
    select user_id into v_next from catcul.room_members where room_id=p_room_id order by joined_at, user_id limit 1;
    if v_next is not null then update catcul.room_members set role='owner' where room_id=p_room_id and user_id=v_next;
    else update catcul.room_invites set revoked_at=now() where room_id=p_room_id and revoked_at is null;
    end if;
  end if;
  -- Empty rooms are retained, inaccessible; no content is silently deleted.
end;
$$;
create or replace function catcul.list_my_rooms()
returns table(id uuid,name text,role text,last_read_at timestamptz,unread_count bigint,last_body text,last_kind text,last_message_at timestamptz)
language sql stable security invoker set search_path = '' as $$
  select r.id,r.name,me.role,me.last_read_at,
    (select count(*) from catcul.messages m where m.room_id=r.id and m.sender_id<>auth.uid() and m.deleted_at is null and m.created_at>coalesce(me.last_read_at,'-infinity'::timestamptz)),
    last_msg.body,last_msg.kind,last_msg.created_at
  from catcul.room_members me join catcul.rooms r on r.id=me.room_id
  left join lateral (select body,kind,created_at from catcul.messages where room_id=r.id and deleted_at is null order by created_at desc,id desc limit 1) last_msg on true
  where me.user_id=auth.uid() order by coalesce(last_msg.created_at,r.created_at) desc;
$$;
create or replace function catcul.acknowledge_messages(p_ids uuid[],p_read boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  if coalesce(array_length(p_ids,1),0)>200 then raise exception 'Maximum 200 receipts per request.'; end if;
  insert into catcul.message_receipts(room_id,message_id,user_id,read_at)
    select m.room_id,m.id,auth.uid(),case when p_read then now() else null end
    from catcul.messages m where m.id=any(p_ids) and m.sender_id<>auth.uid() and catcul.is_member(m.room_id)
    on conflict (message_id,user_id) do update set read_at=coalesce(catcul.message_receipts.read_at,excluded.read_at);
end;
$$;
create or replace function catcul.mark_room_read(p_room_id uuid,p_through_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_at timestamptz;
begin
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode='42501'; end if;
  select created_at into v_at from catcul.messages where room_id=p_room_id and id=p_through_id;
  if v_at is not null then
    update catcul.room_members set last_read_at=greatest(coalesce(last_read_at,'-infinity'::timestamptz),v_at) where room_id=p_room_id and user_id=auth.uid();
  end if;
end;
$$;
create or replace function catcul.remove_message(p_message_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_message catcul.messages;
begin
  select * into v_message from catcul.messages where id=p_message_id for update;
  if not found or v_message.sender_id is distinct from auth.uid() or not catcul.is_member(v_message.room_id) then raise exception 'You can only remove your own messages in a room you belong to.' using errcode='42501'; end if;
  update catcul.messages set body='',deleted_at=coalesce(deleted_at,now()),attachment_id=null where id=p_message_id;
  if v_message.attachment_id is not null then update catcul.attachments set deleted_at=now() where id=v_message.attachment_id; end if;
  update catcul.message_reactions set active=false where message_id=p_message_id;
  -- Private object retained for administrator retention/cleanup; RLS blocks new reads.
  -- Already downloaded copies and unexpired signed URLs cannot be recalled.
end;
$$;

-- RLS is enabled on EVERY application table, including invite hashes.
alter table catcul.profiles enable row level security;
alter table catcul.rooms enable row level security;
alter table catcul.room_members enable row level security;
alter table catcul.room_invites enable row level security;
alter table catcul.attachments enable row level security;
alter table catcul.messages enable row level security;
alter table catcul.message_reactions enable row level security;
alter table catcul.message_receipts enable row level security;

-- Only our namespaced policies are replaced on reruns.
drop policy if exists catcul_profiles_read on catcul.profiles;
create policy catcul_profiles_read on catcul.profiles for select to authenticated using (catcul.shares_room(id));
drop policy if exists catcul_profiles_edit_self on catcul.profiles;
create policy catcul_profiles_edit_self on catcul.profiles for update to authenticated using (id=(select auth.uid())) with check (id=(select auth.uid()));
drop policy if exists catcul_rooms_read on catcul.rooms;
create policy catcul_rooms_read on catcul.rooms for select to authenticated using (catcul.is_member(id));
drop policy if exists catcul_members_read on catcul.room_members;
create policy catcul_members_read on catcul.room_members for select to authenticated using (catcul.is_member(room_id));
-- room_invites: deliberately no client read/write policies or grants. RPCs only.
drop policy if exists catcul_attachments_read on catcul.attachments;
create policy catcul_attachments_read on catcul.attachments for select to authenticated using (deleted_at is null and catcul.is_member(room_id));
drop policy if exists catcul_attachments_insert on catcul.attachments;
create policy catcul_attachments_insert on catcul.attachments for insert to authenticated with check (
  uploaded_by=(select auth.uid()) and deleted_at is null and catcul.is_member(room_id)
);
drop policy if exists catcul_messages_read on catcul.messages;
create policy catcul_messages_read on catcul.messages for select to authenticated using (catcul.is_member(room_id));
drop policy if exists catcul_messages_insert on catcul.messages;
create policy catcul_messages_insert on catcul.messages for insert to authenticated with check (
  sender_id=(select auth.uid()) and deleted_at is null and catcul.is_member(room_id)
  and (reply_to is null or exists(select 1 from catcul.messages parent where parent.id=messages.reply_to and parent.room_id=messages.room_id))
  and (attachment_id is null or exists (
    select 1 from catcul.attachments a where a.id=attachment_id and a.room_id=messages.room_id
      and a.uploaded_by=(select auth.uid()) and a.deleted_at is null
      and ((kind='photo' and a.mime_type like 'image/%') or (kind='audio' and a.mime_type like 'audio/%'))
  ))
);
drop policy if exists catcul_reactions_read on catcul.message_reactions;
create policy catcul_reactions_read on catcul.message_reactions for select to authenticated using (catcul.is_member(room_id));
drop policy if exists catcul_reactions_insert on catcul.message_reactions;
create policy catcul_reactions_insert on catcul.message_reactions for insert to authenticated with check (
  user_id=(select auth.uid()) and catcul.is_member(room_id) and exists(select 1 from catcul.messages m where m.id=message_id and m.deleted_at is null)
);
drop policy if exists catcul_reactions_update on catcul.message_reactions;
create policy catcul_reactions_update on catcul.message_reactions for update to authenticated
using (user_id=(select auth.uid()) and catcul.is_member(room_id))
with check (user_id=(select auth.uid()) and catcul.is_member(room_id) and exists(select 1 from catcul.messages m where m.id=message_id and m.deleted_at is null));
drop policy if exists catcul_receipts_read on catcul.message_receipts;
create policy catcul_receipts_read on catcul.message_receipts for select to authenticated using (catcul.is_member(room_id));

-- Least-privilege column grants: no user-supplied sender IDs, timestamps or deletion flags.
revoke all on all tables in schema catcul from public, anon, authenticated;
grant select on catcul.profiles,catcul.rooms,catcul.room_members,catcul.attachments,catcul.messages,catcul.message_reactions,catcul.message_receipts to authenticated;
grant update(display_name,color) on catcul.profiles to authenticated;
grant insert(id,room_id,object_path,mime_type,byte_size) on catcul.attachments to authenticated;
grant insert(id,room_id,body,kind,attachment_id,reply_to) on catcul.messages to authenticated;
grant insert(room_id,message_id,user_id,emoji,active) on catcul.message_reactions to authenticated;
grant update(active) on catcul.message_reactions to authenticated;
-- Use an RPC for reaction toggles so PostgREST upsert doesn't need broad column UPDATE grants.
create or replace function catcul.set_reaction(p_message_id uuid,p_emoji text,p_active boolean)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_room uuid;
begin
  select room_id into v_room from catcul.messages where id=p_message_id and deleted_at is null;
  if not found then raise exception 'Message unavailable.' using errcode='42501'; end if;
  insert into catcul.message_reactions(room_id,message_id,user_id,emoji,active)
    values(v_room,p_message_id,auth.uid(),p_emoji,p_active)
    on conflict(message_id,user_id,emoji) do update set active=excluded.active;
end;
$$;
revoke all on all functions in schema catcul from public, anon, authenticated;
grant execute on function catcul.is_member(uuid),catcul.shares_room(uuid),catcul.topic_allowed(text),catcul.can_upload_media(text),catcul.can_read_media(text) to authenticated;
grant execute on function catcul.ensure_profile(),catcul.create_room(text),catcul.create_invite(uuid),catcul.join_room(text),catcul.revoke_invites(uuid),catcul.leave_room(uuid),catcul.list_my_rooms(),catcul.acknowledge_messages(uuid[],boolean),catcul.mark_room_read(uuid,uuid),catcul.remove_message(uuid),catcul.set_reaction(uuid,text,boolean) to authenticated;
grant all on all tables in schema catcul to service_role;
grant all on all functions in schema catcul to service_role;

-- Private storage: paths are <room UUID>/<uploader UUID>/<file UUID>.<extension>.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('catcul-media','catcul-media',false,5242880,array['image/jpeg','image/png','image/webp','audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists catcul_media_upload on storage.objects;
create policy catcul_media_upload on storage.objects for insert to authenticated
with check (bucket_id='catcul-media' and catcul.can_upload_media(name));
drop policy if exists catcul_media_read on storage.objects;
create policy catcul_media_read on storage.objects for select to authenticated
using (bucket_id='catcul-media' and catcul.can_read_media(name));
-- No client overwrite/delete permissions. Use an administrator retention task for cleanup.

-- Private Realtime Broadcast/Presence for typing and online presence only.
-- Durable content is streamed from RLS-protected Postgres Changes, never peer-authored.
drop policy if exists catcul_realtime_read on realtime.messages;
create policy catcul_realtime_read on realtime.messages for select to authenticated
using (extension in ('broadcast','presence') and catcul.topic_allowed((select realtime.topic())));
drop policy if exists catcul_realtime_write on realtime.messages;
create policy catcul_realtime_write on realtime.messages for insert to authenticated
with check (extension in ('broadcast','presence') and catcul.topic_allowed((select realtime.topic())));

-- Restrictive bucket/topic guards stop unrelated permissive policies in an existing
-- project from accidentally widening access to Catcul resources. Other resources
-- are unaffected. These supplement (do not replace) the allow policies above.
drop policy if exists catcul_media_guard_read on storage.objects;
create policy catcul_media_guard_read on storage.objects as restrictive for select to authenticated
using (bucket_id <> 'catcul-media' or catcul.can_read_media(name));
drop policy if exists catcul_media_guard_insert on storage.objects;
create policy catcul_media_guard_insert on storage.objects as restrictive for insert to authenticated
with check (bucket_id <> 'catcul-media' or catcul.can_upload_media(name));
drop policy if exists catcul_media_guard_update on storage.objects;
create policy catcul_media_guard_update on storage.objects as restrictive for update to authenticated
using (bucket_id <> 'catcul-media') with check (bucket_id <> 'catcul-media');
drop policy if exists catcul_media_guard_delete on storage.objects;
create policy catcul_media_guard_delete on storage.objects as restrictive for delete to authenticated
using (bucket_id <> 'catcul-media');
drop policy if exists catcul_media_guard_anon on storage.objects;
create policy catcul_media_guard_anon on storage.objects as restrictive for all to anon
using (bucket_id <> 'catcul-media') with check (bucket_id <> 'catcul-media');
drop policy if exists catcul_realtime_guard_read on realtime.messages;
create policy catcul_realtime_guard_read on realtime.messages as restrictive for select to authenticated
using ((select realtime.topic()) not like 'catcul:%' or catcul.topic_allowed((select realtime.topic())));
drop policy if exists catcul_realtime_guard_write on realtime.messages;
create policy catcul_realtime_guard_write on realtime.messages as restrictive for insert to authenticated
with check ((select realtime.topic()) not like 'catcul:%' or catcul.topic_allowed((select realtime.topic())));
drop policy if exists catcul_realtime_guard_anon on realtime.messages;
create policy catcul_realtime_guard_anon on realtime.messages as restrictive for all to anon
using ((select realtime.topic()) not like 'catcul:%') with check ((select realtime.topic()) not like 'catcul:%');

-- Publication changes are idempotent and contain no invitation secrets.
do $$
declare t text;
begin
  if not exists(select 1 from pg_publication where pubname='supabase_realtime') then
    execute 'create publication supabase_realtime';
  end if;
  foreach t in array array['messages','message_reactions','message_receipts','room_members','profiles'] loop
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='catcul' and tablename=t) then
      execute format('alter publication supabase_realtime add table catcul.%I',t);
    end if;
  end loop;
end;
$$;
notify pgrst, 'reload schema';
commit;

-- Verify after installation (expected: eight tables, all rls_enabled=true):
select c.relname as table_name,c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='catcul' and c.relkind='r' order by c.relname;
