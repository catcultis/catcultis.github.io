-- CATCUL / 002 — Friends, best friends, direct messages, groups and voice calls
-- Run AFTER catcul-setup.sql. Non-destructive upgrade; existing rooms become groups.
-- This migration has not been run on your external project by the assistant.
-- Calls additionally require the authenticated catcul-calls Edge Function + LiveKit Cloud.
begin;

alter table catcul.profiles add column if not exists username text;
update catcul.profiles set username='cat_'||replace(id::text,'-','') where username is null;
alter table catcul.profiles alter column username set default ('cat_'||replace(gen_random_uuid()::text,'-',''));
alter table catcul.profiles alter column username set not null;
create unique index if not exists catcul_profiles_username_unique on catcul.profiles(lower(username));
do $$ begin
 if not exists(select 1 from pg_constraint where conname='catcul_username_format' and conrelid='catcul.profiles'::regclass) then
  alter table catcul.profiles add constraint catcul_username_format check(username=lower(username) and username ~ '^[a-z0-9_]{3,40}$');
 end if;
end $$;
grant update(username) on catcul.profiles to authenticated;

create table if not exists catcul.friendships (
 user_low uuid not null references catcul.profiles(id) on delete cascade,
 user_high uuid not null references catcul.profiles(id) on delete cascade,
 requested_by uuid not null references catcul.profiles(id),
 status text not null check(status in ('pending','accepted','declined','cancelled','ended')),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 primary key(user_low,user_high),
 check(user_low<user_high and requested_by in (user_low,user_high))
);
create index if not exists catcul_friendships_high on catcul.friendships(user_high,status);
create index if not exists catcul_friendships_requester on catcul.friendships(requested_by,updated_at);
create table if not exists catcul.best_friends (
 owner_id uuid not null references catcul.profiles(id) on delete cascade,
 friend_id uuid not null references catcul.profiles(id) on delete cascade,
 is_favorite boolean not null default true,
 updated_at timestamptz not null default now(),
 primary key(owner_id,friend_id),check(owner_id<>friend_id)
);
create table if not exists catcul.user_blocks (
 blocker_id uuid not null references catcul.profiles(id) on delete cascade,
 blocked_id uuid not null references catcul.profiles(id) on delete cascade,
 active boolean not null default true,
 created_at timestamptz not null default now(),
 primary key(blocker_id,blocked_id),check(blocker_id<>blocked_id)
);
create index if not exists catcul_blocks_target on catcul.user_blocks(blocked_id) where active;

alter table catcul.rooms add column if not exists kind text not null default 'group';
alter table catcul.rooms add column if not exists direct_low uuid references catcul.profiles(id);
alter table catcul.rooms add column if not exists direct_high uuid references catcul.profiles(id);
alter table catcul.room_members add column if not exists removed_at timestamptz;
alter table catcul.room_members add column if not exists hidden boolean not null default false;
do $$ begin
 if not exists(select 1 from pg_constraint where conname='catcul_room_kind_check' and conrelid='catcul.rooms'::regclass) then
  alter table catcul.rooms add constraint catcul_room_kind_check check ((kind='group' and direct_low is null and direct_high is null) or (kind='direct' and direct_low is not null and direct_high is not null and direct_low<direct_high));
 end if;
end $$;
create unique index if not exists catcul_direct_pair_unique on catcul.rooms(direct_low,direct_high) where kind='direct';

create table if not exists catcul.voice_calls (
 id uuid primary key default gen_random_uuid(),
 room_id uuid not null references catcul.rooms(id),
 started_by uuid not null references catcul.profiles(id),
 status text not null default 'ringing' check(status in ('ringing','active','ended','missed','declined','cancelled')),
 started_at timestamptz not null default now(),
 answered_at timestamptz,
 ended_at timestamptz,
 ended_by uuid references catcul.profiles(id),
 unique(id,room_id)
);
create unique index if not exists catcul_one_live_call on catcul.voice_calls(room_id) where ended_at is null;
create index if not exists catcul_voice_calls_recent on catcul.voice_calls(room_id,started_at desc);
create table if not exists catcul.call_participants (
 call_id uuid not null,
 room_id uuid not null,
 user_id uuid not null references catcul.profiles(id),
 state text not null default 'invited' check(state in ('invited','accepted','declined','left','missed')),
 joined_at timestamptz,
 last_seen_at timestamptz,
 left_at timestamptz,
 primary key(call_id,user_id),
 foreign key(call_id,room_id) references catcul.voice_calls(id,room_id)
);
create index if not exists catcul_calls_by_user on catcul.call_participants(user_id,call_id);

create or replace function catcul.is_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from catcul.room_members where room_id=p_room_id and user_id=auth.uid() and removed_at is null);
$$;
create or replace function catcul.blocked_with(p_other uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from catcul.user_blocks where active and ((blocker_id=auth.uid() and blocked_id=p_other) or (blocked_id=auth.uid() and blocker_id=p_other)));
$$;
create or replace function catcul.are_friends(p_other uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select not catcul.blocked_with(p_other) and exists(select 1 from catcul.friendships where user_low=least(auth.uid(),p_other) and user_high=greatest(auth.uid(),p_other) and status='accepted');
$$;
create or replace function catcul.shares_room(p_user_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select p_user_id=auth.uid() or catcul.are_friends(p_user_id) or exists(
 select 1 from catcul.room_members a join catcul.room_members b on a.room_id=b.room_id where a.user_id=auth.uid() and b.user_id=p_user_id and a.removed_at is null and b.removed_at is null);
$$;
create or replace function catcul.can_send_to_room(p_room_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select catcul.is_member(p_room_id) and exists(select 1 from catcul.rooms r where r.id=p_room_id and (r.kind='group' or catcul.are_friends(case when r.direct_low=auth.uid() then r.direct_high else r.direct_low end)));
$$;
create or replace function catcul.topic_allowed(p_topic text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if p_topic='catcul:user:'||coalesce(auth.uid()::text,'') and auth.uid() is not null then return true; end if;
 if p_topic !~ '^catcul:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
 return catcul.can_send_to_room(split_part(p_topic,':',2)::uuid);
end $$;

create or replace function catcul.find_people(p_query text)
returns table(id uuid,username text,display_name text,color text)
language plpgsql stable security definer set search_path='' as $$
declare q text:=lower(ltrim(btrim(p_query),'@'));
begin
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
 if q is null or char_length(q)<3 or char_length(q)>40 or q !~ '^[a-z0-9_]+$' then return; end if;
 return query select p.id,p.username,p.display_name,p.color from catcul.profiles p
 where p.id<>auth.uid() and not catcul.blocked_with(p.id) and left(p.username,char_length(q))=q
 order by (p.username=q) desc,p.username limit 20;
end $$;
create or replace function catcul.social_state()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); result jsonb;
begin
 if u is null then raise exception 'Sign in first.' using errcode='42501'; end if;
 select jsonb_build_object(
 'friends',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'best',coalesce(b.is_favorite,false)) order by coalesce(b.is_favorite,false) desc,p.display_name) from catcul.friendships f join catcul.profiles p on p.id=case when f.user_low=u then f.user_high else f.user_low end left join catcul.best_friends b on b.owner_id=u and b.friend_id=p.id where u in(f.user_low,f.user_high) and f.status='accepted' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'incoming',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color)) from catcul.friendships f join catcul.profiles p on p.id=f.requested_by where u in(f.user_low,f.user_high) and f.requested_by<>u and f.status='pending' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'outgoing',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color)) from catcul.friendships f join catcul.profiles p on p.id=case when f.user_low=u then f.user_high else f.user_low end where u in(f.user_low,f.user_high) and f.requested_by=u and f.status='pending' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'blocked',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color)) from catcul.user_blocks b join catcul.profiles p on p.id=b.blocked_id where b.blocker_id=u and b.active),'[]'::jsonb)
 ) into result;return result;
end $$;
create or replace function catcul.send_friend_request(p_to uuid)
returns void language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); f catcul.friendships;
begin
 if u is null or u=p_to then raise exception 'Choose another account.' using errcode='42501'; end if;
 perform 1 from catcul.profiles where id=u for update;
 if not exists(select 1 from catcul.profiles where id=p_to) or catcul.blocked_with(p_to) then raise exception 'This person is unavailable.' using errcode='42501'; end if;
 if (select count(*) from catcul.friendships where requested_by=u and updated_at>now()-interval '1 minute')>=10 then raise exception 'Please wait before sending more requests.'; end if;
 if (select count(*) from catcul.friendships where requested_by=u and status='pending')>=100 then raise exception 'You have too many pending requests.'; end if;
 select * into f from catcul.friendships where user_low=least(u,p_to) and user_high=greatest(u,p_to) for update;
 if found then
  if f.status in ('accepted','pending') then raise exception 'You are already friends or a request is pending.'; end if;
  if f.status='declined' and f.requested_by=u and f.updated_at>now()-interval '24 hours' then raise exception 'Please wait before asking this person again.'; end if;
 end if;
 insert into catcul.friendships(user_low,user_high,requested_by,status) values(least(u,p_to),greatest(u,p_to),u,'pending')
 on conflict(user_low,user_high) do update set requested_by=u,status='pending',updated_at=now();
end $$;
create or replace function catcul.respond_friend_request(p_from uuid,p_accept boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or catcul.blocked_with(p_from) then raise exception 'Request unavailable.' using errcode='42501'; end if;
 update catcul.friendships set status=case when p_accept then 'accepted' else 'declined' end,updated_at=now()
 where user_low=least(auth.uid(),p_from) and user_high=greatest(auth.uid(),p_from) and status='pending' and requested_by=p_from;
 if not found then raise exception 'That request is no longer pending.'; end if;
end $$;
create or replace function catcul.remove_friend(p_other uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 update catcul.friendships set status=case when status='pending' then 'cancelled' else 'ended' end,updated_at=now()
 where user_low=least(auth.uid(),p_other) and user_high=greatest(auth.uid(),p_other) and (status='accepted' or (status='pending' and requested_by=auth.uid()));
 update catcul.best_friends set is_favorite=false,updated_at=now() where (owner_id=auth.uid() and friend_id=p_other) or (owner_id=p_other and friend_id=auth.uid());
 update catcul.voice_calls c set status='ended',ended_at=now(),ended_by=auth.uid() from catcul.rooms r where c.room_id=r.id and r.kind='direct' and r.direct_low=least(auth.uid(),p_other) and r.direct_high=greatest(auth.uid(),p_other) and c.ended_at is null;
end $$;
create or replace function catcul.set_best_friend(p_friend uuid,p_best boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or (p_best and not catcul.are_friends(p_friend)) then raise exception 'Best friends must be accepted friends.' using errcode='42501'; end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 if p_best and (select count(*) from catcul.best_friends where owner_id=auth.uid() and is_favorite and friend_id<>p_friend)>=8 then raise exception 'You can pin up to 8 best friends.'; end if;
 insert into catcul.best_friends(owner_id,friend_id,is_favorite) values(auth.uid(),p_friend,p_best)
 on conflict(owner_id,friend_id) do update set is_favorite=p_best,updated_at=now();
end $$;
create or replace function catcul.set_block(p_other uuid,p_block boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or p_other=auth.uid() then raise exception 'Invalid account.' using errcode='42501'; end if;
 insert into catcul.user_blocks(blocker_id,blocked_id,active) values(auth.uid(),p_other,p_block)
 on conflict(blocker_id,blocked_id) do update set active=p_block,created_at=now();
 if p_block then
  update catcul.friendships set status='ended',updated_at=now() where user_low=least(auth.uid(),p_other) and user_high=greatest(auth.uid(),p_other);
  update catcul.best_friends set is_favorite=false,updated_at=now() where (owner_id=auth.uid() and friend_id=p_other) or (owner_id=p_other and friend_id=auth.uid());
  update catcul.voice_calls c set status='ended',ended_at=now(),ended_by=auth.uid() from catcul.rooms r where c.room_id=r.id and r.kind='direct' and r.direct_low=least(auth.uid(),p_other) and r.direct_high=greatest(auth.uid(),p_other) and c.ended_at is null;
 end if;
end $$;

create or replace function catcul.create_room(p_name text)
returns catcul.rooms language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); r catcul.rooms;
begin
 if u is null then raise exception 'Sign in first.' using errcode='42501'; end if;
 perform catcul.ensure_profile();perform 1 from catcul.profiles where id=u for update;
 if (select count(*) from catcul.room_members where user_id=u and removed_at is null)>=50 then raise exception 'Maximum 50 rooms per account.'; end if;
 if p_name is null or char_length(btrim(p_name)) not between 1 and 40 then raise exception 'Group names must be 1–40 characters.'; end if;
 insert into catcul.rooms(name,created_by,kind) values(btrim(p_name),u,'group') returning * into r;
 insert into catcul.room_members(room_id,user_id,role) values(r.id,u,'owner');return r;
end $$;
create or replace function catcul.start_direct_chat(p_friend uuid)
returns catcul.rooms language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); r catcul.rooms;
begin
 if u is null or not catcul.are_friends(p_friend) then raise exception 'Accept a friend request before starting a private chat.' using errcode='42501'; end if;
 -- Lock both accounts in stable order to serialize room limits and duplicate DMs.
 perform 1 from catcul.profiles where id in(u,p_friend) order by id for update;
 select * into r from catcul.rooms where kind='direct' and direct_low=least(u,p_friend) and direct_high=greatest(u,p_friend);
 if not found then
  if (select count(*) from catcul.room_members where user_id=u and removed_at is null)>=50 or (select count(*) from catcul.room_members where user_id=p_friend and removed_at is null)>=50 then raise exception 'One account has reached the 50-room limit.'; end if;
  insert into catcul.rooms(name,created_by,kind,direct_low,direct_high) values('Private chat',u,'direct',least(u,p_friend),greatest(u,p_friend)) returning * into r;
  insert into catcul.room_members(room_id,user_id,role) values(r.id,u,'member'),(r.id,p_friend,'member');
 end if;
 update catcul.room_members set hidden=false,removed_at=null where room_id=r.id and user_id=u;return r;
end $$;
create or replace function catcul.hide_direct_chat(p_room_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not catcul.is_member(p_room_id) or not exists(select 1 from catcul.rooms where id=p_room_id and kind='direct') then raise exception 'Private chat unavailable.' using errcode='42501'; end if;
 update catcul.room_members set hidden=true where room_id=p_room_id and user_id=auth.uid();
end $$;
create or replace function catcul.unhide_dm_on_message()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from catcul.rooms where id=new.room_id and kind='direct') then
  update catcul.room_members set hidden=false where room_id=new.room_id and hidden;
 end if; return new;
end $$;
drop trigger if exists catcul_unhide_dm on catcul.messages;
create trigger catcul_unhide_dm after insert on catcul.messages for each row execute function catcul.unhide_dm_on_message();
create or replace function catcul.rename_group(p_room_id uuid,p_name text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from catcul.room_members m join catcul.rooms r on r.id=m.room_id where r.id=p_room_id and r.kind='group' and m.user_id=auth.uid() and m.role='owner' and m.removed_at is null) then raise exception 'Only the group owner can rename it.' using errcode='42501'; end if;
 if p_name is null or char_length(btrim(p_name)) not between 1 and 40 then raise exception 'Choose a name of 1–40 characters.'; end if;
 update catcul.rooms set name=btrim(p_name) where id=p_room_id;
end $$;
create or replace function catcul.create_invite(p_room_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare t text;
begin
 if not catcul.is_member(p_room_id) or not exists(select 1 from catcul.rooms where id=p_room_id and kind='group') then raise exception 'Only group chats can be invited to.' using errcode='42501'; end if;
 perform 1 from catcul.rooms where id=p_room_id for update;
 if (select count(*) from catcul.room_invites where room_id=p_room_id and created_at>now()-interval '1 minute')>=10 then raise exception 'Please wait before creating another invitation.'; end if;
 t:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
 insert into catcul.room_invites(room_id,token_hash,created_by) values(p_room_id,encode(sha256(convert_to(t,'UTF8')),'hex'),auth.uid());return t;
end $$;
create or replace function catcul.join_room(p_token text)
returns catcul.rooms language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); inv catcul.room_invites; r catcul.rooms;
begin
 if u is null then raise exception 'Sign in first.' using errcode='42501'; end if;
 if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'Invalid invitation.'; end if;
 perform catcul.ensure_profile();perform 1 from catcul.profiles where id=u for update;
 select * into inv from catcul.room_invites where token_hash=encode(sha256(convert_to(p_token,'UTF8')),'hex') for update;
 if not found or inv.revoked_at is not null or inv.expires_at<=now() or inv.uses>=inv.max_uses then raise exception 'Invitation invalid, expired, revoked or full.'; end if;
 select * into r from catcul.rooms where id=inv.room_id for update;
 if r.kind<>'group' then raise exception 'Private chats cannot be joined by invitation.' using errcode='42501'; end if;
 if catcul.blocked_with(inv.created_by) then raise exception 'Invitation unavailable.' using errcode='42501'; end if;
 if not catcul.is_member(r.id) then
  if (select count(*) from catcul.room_members where user_id=u and removed_at is null)>=50 then raise exception 'Maximum 50 rooms per account.'; end if;
  if (select count(*) from catcul.room_members where room_id=r.id and removed_at is null)>=50 then raise exception 'This group is full (50 members).'; end if;
  insert into catcul.room_members(room_id,user_id) values(r.id,u) on conflict(room_id,user_id) do update set removed_at=null,hidden=false,role='member',joined_at=now();
  update catcul.room_invites set uses=uses+1 where id=inv.id;
 end if;return r;
end $$;
create or replace function catcul.leave_room(p_room_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_role text; v_next uuid;
begin
 perform 1 from catcul.rooms where id=p_room_id for update;
 if not exists(select 1 from catcul.rooms where id=p_room_id and kind='group') then raise exception 'Hide a private chat instead of leaving it.'; end if;
 select role into v_role from catcul.room_members where room_id=p_room_id and user_id=auth.uid() and removed_at is null;
 if v_role is null then raise exception 'Membership required.' using errcode='42501'; end if;
 update catcul.room_members set removed_at=now(),role='member' where room_id=p_room_id and user_id=auth.uid();
 update catcul.call_participants set state='left',left_at=now() where room_id=p_room_id and user_id=auth.uid() and state in('accepted','invited');
 if v_role='owner' then
  select user_id into v_next from catcul.room_members where room_id=p_room_id and removed_at is null order by joined_at,user_id limit 1;
  if v_next is not null then update catcul.room_members set role='owner' where room_id=p_room_id and user_id=v_next;
  else update catcul.room_invites set revoked_at=now() where room_id=p_room_id and revoked_at is null;end if;
 end if;
end $$;
create or replace function catcul.kick_group_member_as(p_actor uuid,p_room_id uuid,p_target uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 if p_actor=p_target or not exists(select 1 from catcul.room_members m join catcul.rooms r on r.id=m.room_id where m.room_id=p_room_id and m.user_id=p_actor and m.role='owner' and m.removed_at is null and r.kind='group') then raise exception 'Only the group owner can remove other members.' using errcode='42501'; end if;
 perform 1 from catcul.rooms where id=p_room_id for update;
 update catcul.room_invites set revoked_at=now() where room_id=p_room_id and revoked_at is null;
 update catcul.room_members set removed_at=coalesce(removed_at,now()),role='member' where room_id=p_room_id and user_id=p_target;
 update catcul.call_participants set state='left',left_at=now() where room_id=p_room_id and user_id=p_target and state in('accepted','invited');
end $$;

-- New function name avoids changing the return signature of the v1 room-list RPC.
create or replace function catcul.list_my_spaces()
returns table(id uuid,name text,kind text,role text,peer_id uuid,peer_name text,peer_color text,can_send boolean,last_read_at timestamptz,unread_count bigint,last_body text,last_kind text,last_message_at timestamptz)
language sql stable security definer set search_path='' as $$
 select r.id,r.name,r.kind,me.role,p.id,p.display_name,p.color,catcul.can_send_to_room(r.id),me.last_read_at,
 (select count(*) from catcul.messages m where m.room_id=r.id and m.sender_id<>auth.uid() and m.deleted_at is null and m.created_at>coalesce(me.last_read_at,'-infinity'::timestamptz)),
 lm.body,lm.kind,lm.created_at from catcul.room_members me join catcul.rooms r on r.id=me.room_id
 left join catcul.profiles p on p.id=case when r.direct_low=auth.uid() then r.direct_high when r.direct_high=auth.uid() then r.direct_low else null end
 left join lateral(select body,kind,created_at from catcul.messages where room_id=r.id and deleted_at is null order by created_at desc,id desc limit 1) lm on true
 where me.user_id=auth.uid() and me.removed_at is null and not me.hidden order by coalesce(lm.created_at,r.created_at) desc;
$$;

-- Expiration is activity-driven; the app refreshes it while open. No cron required.
create or replace function catcul.expire_voice_calls()
returns void language plpgsql security definer set search_path='' as $$
begin
 update catcul.voice_calls c set status=case when c.status='ringing' then 'missed' else 'ended' end,ended_at=now()
 where c.ended_at is null and catcul.is_member(c.room_id) and (
 (c.status='ringing' and c.started_at<now()-interval '75 seconds') or
 (c.started_at<now()-interval '120 seconds' and not exists(select 1 from catcul.call_participants p where p.call_id=c.id and p.state='accepted' and p.last_seen_at>now()-interval '100 seconds')));
end $$;
create or replace function catcul.start_voice_call(p_room_id uuid)
returns catcul.voice_calls language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); c catcul.voice_calls; r catcul.rooms;
begin
 if u is null or not catcul.can_send_to_room(p_room_id) then raise exception 'You cannot call this room.' using errcode='42501'; end if;
 perform catcul.expire_voice_calls();perform 1 from catcul.profiles where id=u for update;
 perform 1 from catcul.rooms where id=p_room_id for update;select * into r from catcul.rooms where id=p_room_id;
 if exists(select 1 from catcul.call_participants p join catcul.voice_calls v on v.id=p.call_id where p.user_id=u and p.state='accepted' and v.ended_at is null and p.last_seen_at>now()-interval '100 seconds') then raise exception 'Leave your current call first.'; end if;
 if exists(select 1 from catcul.voice_calls where room_id=p_room_id and ended_at is null) then raise exception 'This room already has a call. Join it instead.'; end if;
 if (select count(*) from catcul.voice_calls where started_by=u and started_at>now()-interval '1 minute')>=4 then raise exception 'Please wait before calling again.'; end if;
 if r.kind='direct' and exists(select 1 from catcul.call_participants p join catcul.voice_calls v on v.id=p.call_id where p.user_id=case when r.direct_low=u then r.direct_high else r.direct_low end and p.state='accepted' and v.ended_at is null and p.last_seen_at>now()-interval '100 seconds') then raise exception 'Your friend is on another call.'; end if;
 insert into catcul.voice_calls(room_id,started_by) values(p_room_id,u) returning * into c;
 insert into catcul.call_participants(call_id,room_id,user_id,state,last_seen_at)
 select c.id,p_room_id,user_id,case when user_id=u then 'accepted' else 'invited' end,case when user_id=u then now() else null end
 from catcul.room_members where room_id=p_room_id and removed_at is null;
 return c;
end $$;
create or replace function catcul.respond_voice_call(p_call_id uuid,p_accept boolean)
returns catcul.voice_calls language plpgsql security definer set search_path='' as $$
declare c catcul.voice_calls; r catcul.rooms; u uuid:=auth.uid();
begin
 perform catcul.expire_voice_calls();perform 1 from catcul.profiles where id=u for update;
 select * into c from catcul.voice_calls where id=p_call_id for update;
 if not found or c.ended_at is not null or not catcul.can_send_to_room(c.room_id) then raise exception 'This call is no longer available.' using errcode='42501'; end if;
 select * into r from catcul.rooms where id=c.room_id;
 if r.kind='group' then insert into catcul.call_participants(call_id,room_id,user_id) values(c.id,c.room_id,u) on conflict do nothing;end if;
 if not exists(select 1 from catcul.call_participants where call_id=c.id and user_id=u) then raise exception 'You were not invited to this call.' using errcode='42501'; end if;
 if p_accept and exists(select 1 from catcul.call_participants p join catcul.voice_calls v on v.id=p.call_id where p.user_id=u and p.state='accepted' and v.id<>c.id and v.ended_at is null and p.last_seen_at>now()-interval '100 seconds') then raise exception 'Leave your current call first.'; end if;
 update catcul.call_participants set state=case when p_accept then 'accepted' else 'declined' end,last_seen_at=case when p_accept then now() else last_seen_at end,left_at=case when p_accept then null else now() end where call_id=c.id and user_id=u;
 if p_accept and u<>c.started_by then update catcul.voice_calls set status='active',answered_at=coalesce(answered_at,now()) where id=c.id returning * into c;
 elsif not p_accept and r.kind='direct' then update catcul.voice_calls set status='declined',ended_at=now(),ended_by=u where id=c.id returning * into c;end if;
 return c;
end $$;
create or replace function catcul.authorize_voice_join(p_call_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c catcul.voice_calls; p catcul.profiles;
begin
 select * into c from catcul.voice_calls where id=p_call_id;
 if not found or c.ended_at is not null or (c.status='ringing' and c.started_at<now()-interval '75 seconds') or not catcul.can_send_to_room(c.room_id) then raise exception 'Call access denied.' using errcode='42501'; end if;
 if not exists(select 1 from catcul.call_participants where call_id=c.id and user_id=auth.uid() and state='accepted') then raise exception 'Accept the call before joining.' using errcode='42501'; end if;
 select * into p from catcul.profiles where id=auth.uid();
 return jsonb_build_object('call_id',c.id,'room_id',c.room_id,'media_room','catcul_'||replace(c.id::text,'-',''),'identity',p.id,'name',p.display_name,'color',p.color);
end $$;
create or replace function catcul.voice_heartbeat(p_call_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform catcul.authorize_voice_join(p_call_id);
 update catcul.call_participants set joined_at=coalesce(joined_at,now()),last_seen_at=now() where call_id=p_call_id and user_id=auth.uid() and state='accepted';
end $$;
create or replace function catcul.leave_voice_call(p_call_id uuid)
returns catcul.voice_calls language plpgsql security definer set search_path='' as $$
declare c catcul.voice_calls; r catcul.rooms;
begin
 select * into c from catcul.voice_calls where id=p_call_id for update;
 if not found or not exists(select 1 from catcul.call_participants where call_id=c.id and user_id=auth.uid()) then raise exception 'Call unavailable.' using errcode='42501'; end if;
 update catcul.call_participants set state='left',left_at=now() where call_id=c.id and user_id=auth.uid();
 select * into r from catcul.rooms where id=c.room_id;
 if c.ended_at is null and (r.kind='direct' or not exists(select 1 from catcul.call_participants where call_id=c.id and state='accepted' and last_seen_at>now()-interval '100 seconds')) then
  update catcul.voice_calls set status=case when status='ringing' then 'cancelled' else 'ended' end,ended_at=now(),ended_by=auth.uid() where id=c.id returning * into c;
 end if; return c;
end $$;
create or replace function catcul.end_voice_call_as(p_actor uuid,p_call_id uuid)
returns catcul.voice_calls language plpgsql security definer set search_path='' as $$
declare c catcul.voice_calls;
begin
 select * into c from catcul.voice_calls where id=p_call_id for update;
 if not found or not exists(select 1 from catcul.room_members where room_id=c.room_id and user_id=p_actor and removed_at is null and (role='owner' or c.started_by=p_actor)) then raise exception 'Only the caller or group owner can end this call for everyone.' using errcode='42501'; end if;
 update catcul.voice_calls set status='ended',ended_at=coalesce(ended_at,now()),ended_by=p_actor where id=c.id returning * into c;
 update catcul.call_participants set state='left',left_at=coalesce(left_at,now()) where call_id=c.id and state in('accepted','invited');return c;
end $$;
create or replace function catcul.my_voice_calls()
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
 perform catcul.expire_voice_calls();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.started_at desc),'[]'::jsonb) into result from (
 select c.*,r.kind,r.name as room_name,coalesce(p.state,'available') as my_state,sp.display_name as caller_name,sp.color as caller_color,
 case when r.kind='direct' then peer.display_name else r.name end as title
 from catcul.voice_calls c left join catcul.call_participants p on p.call_id=c.id and p.user_id=auth.uid() join catcul.rooms r on r.id=c.room_id join catcul.profiles sp on sp.id=c.started_by
 left join catcul.profiles peer on peer.id=case when r.direct_low=auth.uid() then r.direct_high when r.direct_high=auth.uid() then r.direct_low else null end
 where (p.user_id=auth.uid() or (r.kind='group' and c.ended_at is null)) and catcul.is_member(c.room_id) and c.started_at>now()-interval '7 days' order by c.started_at desc limit 40) x;return result;
end $$;

create or replace function catcul.can_upload_media(p_path text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
begin
  if array_length(string_to_array(p_path,'/'),1) <> 3 or split_part(p_path,'/',1) !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  return split_part(p_path,'/',2) = (select auth.uid())::text
    and catcul.can_send_to_room(split_part(p_path,'/',1)::uuid);
end;
$$;

drop policy if exists catcul_attachments_insert on catcul.attachments;
create policy catcul_attachments_insert on catcul.attachments for insert to authenticated with check(uploaded_by=(select auth.uid()) and deleted_at is null and catcul.can_send_to_room(room_id));
drop policy if exists catcul_reactions_insert on catcul.message_reactions;
create policy catcul_reactions_insert on catcul.message_reactions for insert to authenticated with check(user_id=(select auth.uid()) and catcul.can_send_to_room(room_id) and exists(select 1 from catcul.messages m where m.id=message_reactions.message_id and m.room_id=message_reactions.room_id and m.deleted_at is null));
drop policy if exists catcul_reactions_update on catcul.message_reactions;
create policy catcul_reactions_update on catcul.message_reactions for update to authenticated using(user_id=(select auth.uid()) and catcul.can_send_to_room(room_id)) with check(user_id=(select auth.uid()) and catcul.can_send_to_room(room_id) and exists(select 1 from catcul.messages m where m.id=message_reactions.message_id and m.room_id=message_reactions.room_id and m.deleted_at is null));

-- Membership changes are soft updates so RLS-filtered Realtime can notify removal.
drop policy if exists catcul_members_read on catcul.room_members;
create policy catcul_members_read on catcul.room_members for select to authenticated using(user_id=(select auth.uid()) or (removed_at is null and catcul.is_member(room_id)));
drop policy if exists catcul_messages_insert on catcul.messages;
create policy catcul_messages_insert on catcul.messages for insert to authenticated with check(
 sender_id=(select auth.uid()) and deleted_at is null and catcul.can_send_to_room(room_id)
 and(reply_to is null or exists(select 1 from catcul.messages p where p.id=messages.reply_to and p.room_id=messages.room_id))
 and(attachment_id is null or exists(select 1 from catcul.attachments a where a.id=messages.attachment_id and a.room_id=messages.room_id and a.uploaded_by=(select auth.uid()) and a.deleted_at is null and ((messages.kind='photo' and a.mime_type like 'image/%') or (messages.kind='audio' and a.mime_type like 'audio/%')))));
-- Room history remains readable to both DM participants after unfriend/block;
-- new messages, typing and new calls require the friendship to be active.
alter table catcul.friendships enable row level security;
alter table catcul.best_friends enable row level security;
alter table catcul.user_blocks enable row level security;
alter table catcul.voice_calls enable row level security;
alter table catcul.call_participants enable row level security;
drop policy if exists catcul_friendships_read on catcul.friendships;
create policy catcul_friendships_read on catcul.friendships for select to authenticated using((select auth.uid()) in(user_low,user_high));
drop policy if exists catcul_favorites_read on catcul.best_friends;
create policy catcul_favorites_read on catcul.best_friends for select to authenticated using(owner_id=(select auth.uid()));
drop policy if exists catcul_blocks_read on catcul.user_blocks;
create policy catcul_blocks_read on catcul.user_blocks for select to authenticated using(blocker_id=(select auth.uid()));
drop policy if exists catcul_calls_read on catcul.voice_calls;
create policy catcul_calls_read on catcul.voice_calls for select to authenticated using(catcul.is_member(room_id));
drop policy if exists catcul_call_participants_read on catcul.call_participants;
create policy catcul_call_participants_read on catcul.call_participants for select to authenticated using(user_id=(select auth.uid()) or catcul.is_member(room_id));
revoke all on catcul.friendships,catcul.best_friends,catcul.user_blocks,catcul.voice_calls,catcul.call_participants from public,anon,authenticated;
grant select on catcul.friendships,catcul.best_friends,catcul.user_blocks,catcul.voice_calls,catcul.call_participants to authenticated;
grant all on catcul.friendships,catcul.best_friends,catcul.user_blocks,catcul.voice_calls,catcul.call_participants to service_role;
-- Explicit grants; none of the security-definer functions are PUBLIC-executable.
revoke all on function catcul.blocked_with(uuid),catcul.are_friends(uuid),catcul.can_send_to_room(uuid),catcul.find_people(text),catcul.social_state(),catcul.send_friend_request(uuid),catcul.respond_friend_request(uuid,boolean),catcul.remove_friend(uuid),catcul.set_best_friend(uuid,boolean),catcul.set_block(uuid,boolean),catcul.start_direct_chat(uuid),catcul.hide_direct_chat(uuid),catcul.unhide_dm_on_message(),catcul.rename_group(uuid,text),catcul.kick_group_member_as(uuid,uuid,uuid),catcul.list_my_spaces(),catcul.expire_voice_calls(),catcul.start_voice_call(uuid),catcul.respond_voice_call(uuid,boolean),catcul.authorize_voice_join(uuid),catcul.voice_heartbeat(uuid),catcul.leave_voice_call(uuid),catcul.end_voice_call_as(uuid,uuid),catcul.my_voice_calls() from public,anon,authenticated;
grant execute on function catcul.blocked_with(uuid),catcul.are_friends(uuid),catcul.can_send_to_room(uuid),catcul.find_people(text),catcul.social_state(),catcul.send_friend_request(uuid),catcul.respond_friend_request(uuid,boolean),catcul.remove_friend(uuid),catcul.set_best_friend(uuid,boolean),catcul.set_block(uuid,boolean),catcul.start_direct_chat(uuid),catcul.hide_direct_chat(uuid),catcul.rename_group(uuid,text),catcul.list_my_spaces(),catcul.expire_voice_calls(),catcul.start_voice_call(uuid),catcul.respond_voice_call(uuid,boolean),catcul.authorize_voice_join(uuid),catcul.voice_heartbeat(uuid),catcul.leave_voice_call(uuid),catcul.my_voice_calls() to authenticated;
grant execute on function catcul.kick_group_member_as(uuid,uuid,uuid),catcul.end_voice_call_as(uuid,uuid) to service_role;
grant all on all functions in schema catcul to service_role;

do $$ declare t text;begin
 foreach t in array array['friendships','best_friends','user_blocks','voice_calls','call_participants','rooms'] loop
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='catcul' and tablename=t) then execute format('alter publication supabase_realtime add table catcul.%I',t);end if;
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
select 'Catcul social + voice schema is installed. Configure the Edge Function and LiveKit to activate calls.' as next_step;
