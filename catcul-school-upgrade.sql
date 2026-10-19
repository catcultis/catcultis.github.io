-- CATCUL / 004 — School workspace. Run after 001, 002 and 003.
-- No external project has been changed by the assistant.
begin;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
-- Preserve real usernames; require legacy/generated handles to be chosen on next login.
alter table catcul.profiles drop constraint if exists catcul_username_format;
alter table catcul.profiles alter column username drop not null;
alter table catcul.profiles alter column username drop default;
update catcul.profiles set username=null where username !~ '^[A-Za-z0-9_]{3,15}$' or username ~ '^cat_[0-9a-f]{32}$';
alter table catcul.profiles add constraint catcul_username_format check(username is null or username ~ '^[A-Za-z0-9_]{3,15}$');
create or replace function catcul.username_available(p_username text)
returns boolean language sql stable security definer set search_path='' as $$
 select p_username ~ '^[A-Za-z0-9_]{3,15}$' and not exists(select 1 from catcul.profiles where lower(username)=lower(p_username));
$$;
grant usage on schema catcul to anon;
revoke all on function catcul.username_available(text) from public;
grant execute on function catcul.username_available(text) to anon,authenticated;
create or replace function catcul.register_student_profile()
returns trigger language plpgsql security definer set search_path='' as $$
declare handle text:=new.raw_user_meta_data->>'username';
begin
 if handle is null or handle !~ '^[A-Za-z0-9_]{3,15}$' then raise exception 'Choose Username: 3-15 letters, numbers or underscores.';end if;
 insert into catcul.profiles(id,display_name,username) values(new.id,coalesce(nullif(left(btrim(new.raw_user_meta_data->>'display_name'),28),''),'Student'),handle);
 return new;
exception when unique_violation then raise exception 'Username already in use.';
end $$;
revoke all on function catcul.register_student_profile() from public,anon,authenticated;
drop trigger if exists catcul_register_student on auth.users;
create trigger catcul_register_student after insert on auth.users for each row execute function catcul.register_student_profile();
create or replace function catcul.ensure_profile()
returns catcul.profiles language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); p catcul.profiles;
begin
 if u is null then raise exception 'Sign in first.' using errcode='42501';end if;
 insert into catcul.profiles(id,display_name) select u,coalesce(nullif(left(btrim(raw_user_meta_data->>'display_name'),28),''),'Student') from auth.users where id=u on conflict(id) do nothing;
 select * into strict p from catcul.profiles where id=u;return p;
end $$;
create or replace function catcul.find_people(p_query text)
returns table(id uuid,username text,display_name text,color text) language plpgsql stable security definer set search_path='' as $$
declare q text:=lower(ltrim(btrim(p_query),'@'));
begin
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 if q is null or char_length(q)<3 or char_length(q)>15 or q !~ '^[a-z0-9_]+$' then return;end if;
 return query select p.id,p.username,p.display_name,p.color from catcul.profiles p where p.id<>auth.uid() and not catcul.blocked_with(p.id) and left(lower(p.username),char_length(q))=q order by (lower(p.username)=q) desc,p.username limit 20;
end $$;

create table if not exists catcul.school_config (
 id boolean primary key default true check(id),
 study_password_hash text not null,
 campus_networks cidr[] not null default '{}',
 updated_at timestamptz not null default now()
);
-- Bootstrap passcode only. Replace it through the administrator SQL in the setup guide.
insert into catcul.school_config(id,study_password_hash) values(true,extensions.crypt('unlockcatcul',extensions.gen_salt('bf',10))) on conflict do nothing;
create table if not exists catcul.study_settings (
 user_id uuid primary key references catcul.profiles(id) on delete cascade,
 is_study_mode boolean not null default false,
 failed_attempts integer not null default 0,
 locked_until timestamptz,
 updated_at timestamptz not null default now()
);
alter table catcul.school_config enable row level security;
alter table catcul.study_settings enable row level security;
revoke all on catcul.school_config,catcul.study_settings from public,anon,authenticated;
grant all on catcul.school_config,catcul.study_settings to service_role;
grant select on catcul.study_settings to authenticated;
drop policy if exists study_settings_self on catcul.study_settings;
create policy study_settings_self on catcul.study_settings for select to authenticated using(user_id=(select auth.uid()));
create or replace function catcul.study_locked()
returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select is_study_mode from catcul.study_settings where user_id=auth.uid()),false);
$$;
create or replace function catcul.get_study_state()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 insert into catcul.study_settings(user_id) values(auth.uid()) on conflict do nothing;
 return jsonb_build_object('is_study_mode',catcul.study_locked());
end $$;
create or replace function catcul.enable_study_mode()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 insert into catcul.study_settings(user_id,is_study_mode) values(auth.uid(),true) on conflict(user_id) do update set is_study_mode=true,updated_at=now();
 return jsonb_build_object('is_study_mode',true);
end $$;
create or replace function catcul.unlock_study_mode(p_password text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s catcul.study_settings; expected text;
begin
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 insert into catcul.study_settings(user_id) values(auth.uid()) on conflict do nothing;
 select * into s from catcul.study_settings where user_id=auth.uid() for update;
 if s.locked_until>now() then return jsonb_build_object('ok',false,'is_study_mode',s.is_study_mode,'retry_after',ceil(extract(epoch from s.locked_until-now())));end if;
 select study_password_hash into expected from catcul.school_config where id;
 if p_password is null or octet_length(p_password)>72 or expected is null or extensions.crypt(p_password,expected)<>expected then
  update catcul.study_settings set failed_attempts=case when locked_until is not null then 1 else failed_attempts+1 end,
  locked_until=case when locked_until is null and failed_attempts>=4 then now()+interval '5 minutes' else null end,updated_at=now() where user_id=auth.uid();
  return jsonb_build_object('ok',false,'is_study_mode',s.is_study_mode);
 end if;
 update catcul.study_settings set is_study_mode=false,failed_attempts=0,locked_until=null,updated_at=now() where user_id=auth.uid();
 return jsonb_build_object('ok',true,'is_study_mode',false);
end $$;
-- Service-only, called with the verified caller identity by catcul-school.
create or replace function catcul.check_campus_as(p_actor uuid,p_ip text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ip inet; matched boolean:=false; configured boolean;
begin
 if not exists(select 1 from catcul.profiles where id=p_actor) then raise exception 'Unknown account.';end if;
 select cardinality(campus_networks)>0 into configured from catcul.school_config where id;
 begin ip:=p_ip::inet;exception when others then ip:=null;end;
 select coalesce(bool_or(ip <<= network),false) into matched from catcul.school_config c cross join unnest(c.campus_networks) network where c.id;
 insert into catcul.study_settings(user_id,is_study_mode) values(p_actor,matched or (coalesce(configured,false) and ip is null)) on conflict(user_id) do update set is_study_mode=catcul.study_settings.is_study_mode or excluded.is_study_mode,updated_at=now();
 return jsonb_build_object('public_ip',host(ip),'campus_detected',matched,'network_configured',coalesce(configured,false),'is_study_mode',(select is_study_mode from catcul.study_settings where user_id=p_actor));
end $$;

alter table catcul.rooms add column if not exists purpose text not null default 'social' check(purpose in ('social','course','community'));
alter table catcul.rooms add column if not exists course_code text;
create unique index if not exists catcul_single_community on catcul.rooms(purpose) where purpose='community';
create or replace function catcul.is_member(p_room_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from catcul.room_members m join catcul.rooms r on r.id=m.room_id where m.room_id=p_room_id and m.user_id=auth.uid() and m.removed_at is null and (not catcul.study_locked() or r.purpose='course'));
$$;
create or replace function catcul.create_course(p_name text,p_code text default '')
returns catcul.rooms language plpgsql security definer set search_path='' as $$
declare r catcul.rooms;
begin
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 if p_name is null or char_length(btrim(p_name)) not between 1 and 40 or char_length(p_code)>16 then raise exception 'Use a course name up to 40 characters and code up to 16.';end if;
 if (select count(*) from catcul.room_members where user_id=auth.uid() and removed_at is null)>=50 then raise exception 'Maximum 50 conversations per account.';end if;
 insert into catcul.rooms(name,created_by,kind,purpose,course_code) values(btrim(p_name),auth.uid(),'group','course',nullif(btrim(p_code),'')) returning * into r;
 insert into catcul.room_members(room_id,user_id,role) values(r.id,auth.uid(),'owner');return r;
end $$;
create or replace function catcul.join_community()
returns uuid language plpgsql security definer set search_path='' as $$
declare rid uuid;
begin
 if auth.uid() is null or catcul.study_locked() then raise exception 'Community is available outside Study Mode.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(927431);
 select id into rid from catcul.rooms where purpose='community';
 if rid is null then insert into catcul.rooms(name,created_by,kind,purpose) values('Campus community',null,'group','community') returning id into rid;end if;
 insert into catcul.room_members(room_id,user_id,role) values(rid,auth.uid(),'member') on conflict(room_id,user_id) do update set removed_at=null,hidden=false;return rid;
end $$;
create or replace function catcul.list_workspace_spaces()
returns table(id uuid,name text,kind text,role text,peer_id uuid,peer_name text,peer_color text,can_send boolean,last_read_at timestamptz,unread_count bigint,last_body text,last_kind text,last_message_at timestamptz,purpose text,course_code text)
language sql stable security definer set search_path='' as $$
 select s.*,r.purpose,r.course_code from catcul.list_my_spaces() s join catcul.rooms r on r.id=s.id where catcul.is_member(s.id);
$$;

create table if not exists catcul.pinned_resources (
 id uuid primary key default gen_random_uuid(),room_id uuid not null references catcul.rooms(id),
 title text not null check(char_length(title) between 1 and 120),url text not null check(char_length(url)<=2000 and url ~ '^https://[^[:space:]]+$'),
 created_by uuid not null default auth.uid() references catcul.profiles(id),created_at timestamptz not null default now()
);
create table if not exists catcul.homework (
 id uuid primary key default gen_random_uuid(),room_id uuid not null references catcul.rooms(id),
 title text not null check(char_length(title) between 1 and 120),description text not null default '' check(char_length(description)<=3000),
 due_at timestamptz,created_by uuid not null default auth.uid() references catcul.profiles(id),created_at timestamptz not null default now()
);
create table if not exists catcul.homework_completion (
 homework_id uuid not null references catcul.homework(id) on delete cascade,user_id uuid not null default auth.uid() references catcul.profiles(id),
 done boolean not null default false,primary key(homework_id,user_id)
);
create or replace function catcul.course_owner(p_room_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from catcul.room_members m join catcul.rooms r on r.id=m.room_id where r.id=p_room_id and r.purpose='course' and m.user_id=auth.uid() and m.removed_at is null and m.role='owner');
$$;
alter table catcul.pinned_resources enable row level security;
alter table catcul.homework enable row level security;
alter table catcul.homework_completion enable row level security;
drop policy if exists resources_read on catcul.pinned_resources;
create policy resources_read on catcul.pinned_resources for select to authenticated using(catcul.is_member(room_id));
drop policy if exists resources_add on catcul.pinned_resources;
create policy resources_add on catcul.pinned_resources for insert to authenticated with check(created_by=auth.uid() and catcul.course_owner(room_id));
drop policy if exists resources_remove on catcul.pinned_resources;
create policy resources_remove on catcul.pinned_resources for delete to authenticated using(catcul.course_owner(room_id));
drop policy if exists homework_read on catcul.homework;
create policy homework_read on catcul.homework for select to authenticated using(catcul.is_member(room_id));
drop policy if exists homework_add on catcul.homework;
create policy homework_add on catcul.homework for insert to authenticated with check(created_by=auth.uid() and catcul.course_owner(room_id));
drop policy if exists homework_remove on catcul.homework;
create policy homework_remove on catcul.homework for delete to authenticated using(catcul.course_owner(room_id));
drop policy if exists homework_progress on catcul.homework_completion;
create policy homework_progress on catcul.homework_completion for all to authenticated using(user_id=auth.uid() and exists(select 1 from catcul.homework h where h.id=homework_id and catcul.is_member(h.room_id))) with check(user_id=auth.uid() and exists(select 1 from catcul.homework h where h.id=homework_id and catcul.is_member(h.room_id)));
revoke all on catcul.pinned_resources,catcul.homework,catcul.homework_completion from public,anon,authenticated;
grant select,delete on catcul.pinned_resources,catcul.homework to authenticated;
grant insert(room_id,title,url) on catcul.pinned_resources to authenticated;
grant insert(room_id,title,description,due_at) on catcul.homework to authenticated;
grant select,insert(homework_id,user_id,done),update(done) on catcul.homework_completion to authenticated;
grant all on catcul.pinned_resources,catcul.homework,catcul.homework_completion to service_role;

create table if not exists catcul.study_ai_usage(user_id uuid not null references catcul.profiles(id),requested_at timestamptz not null default now());
create index if not exists study_ai_usage_recent on catcul.study_ai_usage(user_id,requested_at);
alter table catcul.study_ai_usage enable row level security;
revoke all on catcul.study_ai_usage from public,anon,authenticated;
grant all on catcul.study_ai_usage to service_role;
create or replace function catcul.consume_study_request_as(p_actor uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from catcul.study_settings where user_id=p_actor and is_study_mode for update;
 if not found then raise exception 'Gemini is only available in Study Mode.' using errcode='42501';end if;
 if (select count(*) from catcul.study_ai_usage where user_id=p_actor and requested_at>now()-interval '1 minute')>=5 or (select count(*) from catcul.study_ai_usage where user_id=p_actor and requested_at>now()-interval '1 day')>=40 then raise exception 'Study Partner limit reached. Try again later.';end if;
 insert into catcul.study_ai_usage(user_id) values(p_actor);
end $$;
revoke all on function catcul.study_locked(),catcul.get_study_state(),catcul.enable_study_mode(),catcul.unlock_study_mode(text),catcul.check_campus_as(uuid,text),catcul.create_course(text,text),catcul.join_community(),catcul.list_workspace_spaces(),catcul.course_owner(uuid),catcul.consume_study_request_as(uuid) from public,anon,authenticated;
grant execute on function catcul.study_locked(),catcul.get_study_state(),catcul.enable_study_mode(),catcul.unlock_study_mode(text),catcul.create_course(text,text),catcul.join_community(),catcul.list_workspace_spaces(),catcul.course_owner(uuid) to authenticated;
grant execute on function catcul.check_campus_as(uuid,text),catcul.consume_study_request_as(uuid) to service_role;
grant execute on all functions in schema catcul to service_role;
create or replace function catcul.topic_allowed(p_topic text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then return false;end if;
 if p_topic in ('catcul:user:'||auth.uid()::text,'catcul:school:'||auth.uid()::text) then return true;end if;
 if p_topic !~ '^catcul:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false;end if;
 return catcul.can_send_to_room(split_part(p_topic,':',2)::uuid);
end $$;

-- Additional guarded overrides are appended before COMMIT by the release builder.
create or replace function catcul.create_room(p_name text)
returns catcul.rooms language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); r catcul.rooms;
begin
 if catcul.study_locked() then raise exception 'Unlock Study Mode with the passcode first.' using errcode='42501';end if;
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
 if catcul.study_locked() then raise exception 'Unlock Study Mode with the passcode first.' using errcode='42501';end if;
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

create or replace function catcul.send_friend_request(p_to uuid)
returns void language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); f catcul.friendships;
begin
 if catcul.study_locked() then raise exception 'Unlock Study Mode with the passcode first.' using errcode='42501';end if;
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
 if catcul.study_locked() then raise exception 'Unlock Study Mode with the passcode first.' using errcode='42501';end if;
 if auth.uid() is null or catcul.blocked_with(p_from) then raise exception 'Request unavailable.' using errcode='42501'; end if;
 update catcul.friendships set status=case when p_accept then 'accepted' else 'declined' end,updated_at=now()
 where user_low=least(auth.uid(),p_from) and user_high=greatest(auth.uid(),p_from) and status='pending' and requested_by=p_from;
 if not found then raise exception 'That request is no longer pending.'; end if;
end $$;

create or replace function catcul.set_best_friend(p_friend uuid,p_best boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
 if catcul.study_locked() then raise exception 'Unlock Study Mode with the passcode first.' using errcode='42501';end if;
 if auth.uid() is null or (p_best and not catcul.are_friends(p_friend)) then raise exception 'Best friends must be accepted friends.' using errcode='42501'; end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 if p_best and (select count(*) from catcul.best_friends where owner_id=auth.uid() and is_favorite and friend_id<>p_friend)>=8 then raise exception 'You can pin up to 8 best friends.'; end if;
 insert into catcul.best_friends(owner_id,friend_id,is_favorite) values(auth.uid(),p_friend,p_best)
 on conflict(owner_id,friend_id) do update set is_favorite=p_best,updated_at=now();
end $$;

create or replace function catcul.create_invite(p_room_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare t text;
begin
 if not catcul.is_member(p_room_id) or not exists(select 1 from catcul.rooms where id=p_room_id and kind='group' and purpose<>'community') then raise exception 'Only group chats can be invited to.' using errcode='42501'; end if;
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
 if r.purpose='community' or (catcul.study_locked() and r.purpose<>'course') then raise exception 'This room cannot be joined here.' using errcode='42501';end if;
 if r.kind<>'group' then raise exception 'Private chats cannot be joined by invitation.' using errcode='42501'; end if;
 if catcul.blocked_with(inv.created_by) then raise exception 'Invitation unavailable.' using errcode='42501'; end if;
 if not catcul.is_member(r.id) then
  if (select count(*) from catcul.room_members where user_id=u and removed_at is null)>=50 then raise exception 'Maximum 50 rooms per account.'; end if;
  if (select count(*) from catcul.room_members where room_id=r.id and removed_at is null)>=50 then raise exception 'This group is full (50 members).'; end if;
  insert into catcul.room_members(room_id,user_id) values(r.id,u) on conflict(room_id,user_id) do update set removed_at=null,hidden=false,role='member',joined_at=now();
  update catcul.room_invites set uses=uses+1 where id=inv.id;
 end if;return r;
end $$;

create or replace function catcul.rename_group(p_room_id uuid,p_name text)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from catcul.room_members m join catcul.rooms r on r.id=m.room_id where r.id=p_room_id and r.kind='group' and r.purpose<>'community' and m.user_id=auth.uid() and m.role='owner' and m.removed_at is null) then raise exception 'Only the group owner can rename it.' using errcode='42501'; end if;
 if p_name is null or char_length(btrim(p_name)) not between 1 and 40 then raise exception 'Choose a name of 1–40 characters.'; end if;
 update catcul.rooms set name=btrim(p_name) where id=p_room_id;
end $$;

create or replace function catcul.leave_room(p_room_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_role text; v_next uuid;
begin
 perform 1 from catcul.rooms where id=p_room_id for update;
 if not exists(select 1 from catcul.rooms where id=p_room_id and kind='group' and purpose<>'community') then raise exception 'Hide a private chat instead of leaving it.'; end if;
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

create or replace function catcul.start_voice_call(p_room_id uuid)
returns catcul.voice_calls language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); c catcul.voice_calls; r catcul.rooms;
begin
 if exists(select 1 from catcul.rooms where id=p_room_id and purpose='community') then raise exception 'Community is text/media chat only.' using errcode='42501';end if;
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

create or replace function catcul.list_my_spaces()
returns table(id uuid,name text,kind text,role text,peer_id uuid,peer_name text,peer_color text,can_send boolean,last_read_at timestamptz,unread_count bigint,last_body text,last_kind text,last_message_at timestamptz)
language sql stable security definer set search_path='' as $$
 select r.id,r.name,r.kind,me.role,p.id,p.display_name,p.color,catcul.can_send_to_room(r.id),me.last_read_at,
 (select count(*) from catcul.messages m where m.room_id=r.id and m.sender_id<>auth.uid() and m.deleted_at is null and m.created_at>coalesce(me.last_read_at,'-infinity'::timestamptz)),
 lm.body,lm.kind,lm.created_at from catcul.room_members me join catcul.rooms r on r.id=me.room_id
 left join catcul.profiles p on p.id=case when r.direct_low=auth.uid() then r.direct_high when r.direct_high=auth.uid() then r.direct_low else null end
 left join lateral(select body,kind,created_at from catcul.messages where room_id=r.id and deleted_at is null order by created_at desc,id desc limit 1) lm on true
 where catcul.is_member(r.id) and me.user_id=auth.uid() and me.removed_at is null and not me.hidden order by coalesce(lm.created_at,r.created_at) desc;
$$;

create or replace function catcul.social_state()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); result jsonb;
begin
 if catcul.study_locked() then return '{"friends":[],"incoming":[],"outgoing":[],"blocked":[]}'::jsonb;end if;
 if u is null then raise exception 'Sign in first.' using errcode='42501'; end if;
 select jsonb_build_object(
 'friends',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'avatar',p.avatar,'best',coalesce(b.is_favorite,false)) order by coalesce(b.is_favorite,false) desc,p.display_name) from catcul.friendships f join catcul.profiles p on p.id=case when f.user_low=u then f.user_high else f.user_low end left join catcul.best_friends b on b.owner_id=u and b.friend_id=p.id where u in(f.user_low,f.user_high) and f.status='accepted' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'incoming',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'avatar',p.avatar)) from catcul.friendships f join catcul.profiles p on p.id=f.requested_by where u in(f.user_low,f.user_high) and f.requested_by<>u and f.status='pending' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'outgoing',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'avatar',p.avatar)) from catcul.friendships f join catcul.profiles p on p.id=case when f.user_low=u then f.user_high else f.user_low end where u in(f.user_low,f.user_high) and f.requested_by=u and f.status='pending' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'blocked',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'avatar',p.avatar)) from catcul.user_blocks b join catcul.profiles p on p.id=b.blocked_id where b.blocker_id=u and b.active),'[]'::jsonb)
 ) into result;return result;
end $$;

do $$declare t text;begin
 foreach t in array array['study_settings','pinned_resources','homework','homework_completion'] loop
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='catcul' and tablename=t) then execute format('alter publication supabase_realtime add table catcul.%I',t);end if;end loop;
end $$;
notify pgrst,'reload schema';
commit;
select 'Catcul school workspace installed. Change the default passcode and configure catcul-school secrets and campus CIDRs.' as next_step;
