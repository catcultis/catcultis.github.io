-- Catcul student workspace: private diary, owner administration and moderation.
-- Run AFTER catcul-study-groups-upgrade.sql. No teacher accounts are introduced.
begin;

create table if not exists catcul.platform_admins (
 user_id uuid primary key references catcul.profiles(id),
 role text not null default 'owner' check(role in ('owner','admin')),
 created_at timestamptz not null default now()
);
create table if not exists catcul.account_controls (
 user_id uuid primary key references catcul.profiles(id),
 suspended boolean not null default false,
 reason text not null default '' check(char_length(reason)<=500),
 updated_by uuid references catcul.profiles(id),updated_at timestamptz not null default now()
);
alter table catcul.platform_admins enable row level security;
alter table catcul.account_controls enable row level security;
revoke all on catcul.platform_admins,catcul.account_controls from public,anon,authenticated;
grant all on catcul.platform_admins,catcul.account_controls to service_role;

create or replace function catcul.account_is_active()
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and not exists(select 1 from catcul.account_controls where user_id=auth.uid() and suspended);
$$;
create or replace function catcul.assert_active_account()
returns void language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is not null and not catcul.account_is_active() then
  raise exception 'Your Catcul account is suspended. Contact the app administrator.' using errcode='42501';
 end if;
end $$;
create or replace function catcul.is_platform_admin()
returns boolean language sql stable security definer set search_path='' as $$
 select catcul.account_is_active() and exists(select 1 from catcul.platform_admins where user_id=auth.uid());
$$;
create or replace function catcul.require_platform_admin()
returns void language plpgsql stable security definer set search_path='' as $$
begin
 if not catcul.is_platform_admin() then raise exception 'Administrator access required.' using errcode='42501';end if;
end $$;
create or replace function catcul.get_app_access()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('active',catcul.account_is_active(),'is_admin',catcul.is_platform_admin(),
  'role',(select role from catcul.platform_admins where user_id=auth.uid()),
  'reason',(select reason from catcul.account_controls where user_id=auth.uid() and suspended));
$$;
revoke all on function catcul.account_is_active(),catcul.assert_active_account(),catcul.is_platform_admin(),catcul.require_platform_admin(),catcul.get_app_access() from public,anon,authenticated;
grant execute on function catcul.account_is_active(),catcul.assert_active_account(),catcul.is_platform_admin(),catcul.require_platform_admin(),catcul.get_app_access() to authenticated,service_role;
-- Existing public username availability may call the active-account guard.
grant execute on function catcul.assert_active_account() to anon;

create table if not exists catcul.diary_entries (
 id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references catcul.profiles(id),
 title text not null default '' check(char_length(title)<=120),
 body text not null default '' check(char_length(body)<=20000),
 mood text not null default '' check(mood in ('','good','okay','low','focused','tired')),
 entry_date date not null default current_date,
 revision bigint not null default 1,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create index if not exists diary_owner_date on catcul.diary_entries(user_id,entry_date desc,updated_at desc);
alter table catcul.diary_entries enable row level security;
revoke all on catcul.diary_entries from public,anon,authenticated;
grant select,delete on catcul.diary_entries to authenticated;
grant insert(id,user_id,title,body,mood,entry_date) on catcul.diary_entries to authenticated;
grant update(title,body,mood,entry_date) on catcul.diary_entries to authenticated;
grant all on catcul.diary_entries to service_role;
drop policy if exists diary_owner_only on catcul.diary_entries;
create policy diary_owner_only on catcul.diary_entries for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
create or replace function catcul.diary_revision()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='UPDATE' then new.revision=old.revision+1;new.created_at=old.created_at;new.id=old.id;new.user_id=old.user_id;end if;
 new.updated_at=now();return new;
end $$;
drop trigger if exists diary_revision on catcul.diary_entries;
create trigger diary_revision before update on catcul.diary_entries for each row execute function catcul.diary_revision();

create table if not exists catcul.message_reports (
 id uuid primary key default gen_random_uuid(),message_id uuid not null references catcul.messages(id),
 room_id uuid not null references catcul.rooms(id),reporter_id uuid not null references catcul.profiles(id),
 category text not null check(category in ('spam','harassment','unsafe','other')),
 detail text not null default '' check(char_length(detail)<=1000),
 snapshot_body text not null,snapshot_kind text not null,snapshot_sender_id uuid not null references catcul.profiles(id),
 snapshot_attachment_id uuid references catcul.attachments(id),
 status text not null default 'open' check(status in ('open','resolved','dismissed')),
 created_at timestamptz not null default now(),resolved_at timestamptz,resolved_by uuid references catcul.profiles(id),
 resolution text not null default '' check(char_length(resolution)<=500),unique(message_id,reporter_id)
);
create table if not exists catcul.admin_audit (
 id uuid primary key default gen_random_uuid(),actor_id uuid not null references catcul.profiles(id),
 action text not null,target_id uuid,detail jsonb not null default '{}',created_at timestamptz not null default now()
);
alter table catcul.message_reports enable row level security;
alter table catcul.admin_audit enable row level security;
revoke all on catcul.message_reports,catcul.admin_audit from public,anon,authenticated;
grant all on catcul.message_reports,catcul.admin_audit to service_role;

create or replace function catcul.report_message(p_message_id uuid,p_category text,p_detail text default '')
returns uuid language plpgsql security definer set search_path='' as $$
declare m catcul.messages;rid uuid;
begin
 perform catcul.assert_active_account();
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 if p_category is null or p_category not in ('spam','harassment','unsafe','other') or char_length(coalesce(p_detail,''))>1000 then raise exception 'Choose a report category and keep details below 1,000 characters.';end if;
 select * into m from catcul.messages where id=p_message_id and deleted_at is null;
 if not found or not catcul.is_member(m.room_id) then raise exception 'You can only report messages you can access.' using errcode='42501';end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 select id into rid from catcul.message_reports where message_id=m.id and reporter_id=auth.uid();
 if rid is not null then return rid;end if;
 if (select count(*) from catcul.message_reports where reporter_id=auth.uid() and created_at>now()-interval '1 day')>=10 then raise exception 'Daily report limit reached. Contact the administrator for urgent help.';end if;
 insert into catcul.message_reports(message_id,room_id,reporter_id,category,detail,snapshot_body,snapshot_kind,snapshot_sender_id,snapshot_attachment_id)
 values(m.id,m.room_id,auth.uid(),p_category,coalesce(p_detail,''),m.body,m.kind,m.sender_id,m.attachment_id) returning id into rid;
 return rid;
end $$;

create or replace function catcul.admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform catcul.require_platform_admin();
 return jsonb_build_object('accounts',(select count(*) from catcul.profiles),'suspended',(select count(*) from catcul.account_controls where suspended),
  'rooms',(select count(*) from catcul.rooms),'messages',(select count(*) from catcul.messages where deleted_at is null),
  'reports_open',(select count(*) from catcul.message_reports where status='open'),
  'campus_networks',(select to_jsonb(campus_networks) from catcul.school_config where id));
end $$;
create or replace function catcul.admin_accounts(p_query text default '',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform catcul.require_platform_admin();
 return coalesce((select jsonb_agg(to_jsonb(q)) from (
  select p.id,p.display_name,p.username,p.created_at,coalesce(c.suspended,false) as suspended,coalesce(c.reason,'') as reason,
   exists(select 1 from catcul.platform_admins a where a.user_id=p.id) as protected_admin
  from catcul.profiles p left join catcul.account_controls c on c.user_id=p.id
  where p.username ilike '%'||left(coalesce(p_query,''),100)||'%' or p.display_name ilike '%'||left(coalesce(p_query,''),100)||'%'
  order by p.created_at desc,p.id limit 30 offset greatest(0,least(coalesce(p_offset,0),100000))
 )q),'[]'::jsonb);
end $$;
create or replace function catcul.admin_reports(p_status text default 'open',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform catcul.require_platform_admin();
 return coalesce((select jsonb_agg(to_jsonb(q)) from (
  select r.*,p.username as sender_username,p.display_name as sender_name,rp.username as reporter_username,rm.name as room_name
  from catcul.message_reports r join catcul.profiles p on p.id=r.snapshot_sender_id join catcul.profiles rp on rp.id=r.reporter_id join catcul.rooms rm on rm.id=r.room_id
  where r.status=p_status order by r.created_at desc limit 30 offset greatest(0,least(coalesce(p_offset,0),100000))
 )q),'[]'::jsonb);
end $$;
create or replace function catcul.admin_community(p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform catcul.require_platform_admin();
 return coalesce((select jsonb_agg(to_jsonb(q)) from (
  select m.id,m.body,m.kind,m.created_at,m.deleted_at,p.username,p.display_name
  from catcul.messages m join catcul.rooms r on r.id=m.room_id join catcul.profiles p on p.id=m.sender_id
  where r.purpose='community' order by m.created_at desc,m.id limit 30 offset greatest(0,least(coalesce(p_offset,0),100000))
 )q),'[]'::jsonb);
end $$;
create or replace function catcul.admin_save_school(p_networks text[],p_new_password text default null)
returns void language plpgsql security definer set search_path='' as $$
declare nets cidr[];
begin
 perform catcul.require_platform_admin();
 if p_networks is null or coalesce(cardinality(p_networks),0)>20 then raise exception 'Use at most 20 campus networks.';end if;
 begin select coalesce(array_agg(distinct n::cidr),'{}'::cidr[]) into nets from unnest(p_networks) n;exception when others then raise exception 'Use valid public IP addresses or CIDRs. A single IPv4 address can end in /32.';end;
 if p_new_password is not null and (octet_length(p_new_password)<10 or octet_length(p_new_password)>72) then raise exception 'Use a new passcode of 10–72 UTF-8 bytes.';end if;
 update catcul.school_config set campus_networks=nets,study_password_hash=case when p_new_password is null then study_password_hash else extensions.crypt(p_new_password,extensions.gen_salt('bf',10)) end,updated_at=now() where id;
 insert into catcul.admin_audit(actor_id,action,detail) values(auth.uid(),'school_settings',jsonb_build_object('networks',nets,'password_changed',p_new_password is not null));
end $$;
create or replace function catcul.admin_set_account_status(p_target uuid,p_suspended boolean,p_reason text default '')
returns void language plpgsql security definer set search_path='' as $$
begin
 perform catcul.require_platform_admin();
 if p_target is null or p_suspended is null or not exists(select 1 from catcul.profiles where id=p_target) then raise exception 'Account not found.';end if;
 if exists(select 1 from catcul.platform_admins where user_id=p_target) then raise exception 'Administrator accounts are protected. Change administrator access privately in SQL Editor.' using errcode='42501';end if;
 if char_length(coalesce(p_reason,''))>500 or (p_suspended and char_length(btrim(coalesce(p_reason,'')))<3) then raise exception 'Provide a reason of 3–500 characters for suspension.';end if;
 insert into catcul.account_controls(user_id,suspended,reason,updated_by) values(p_target,p_suspended,coalesce(p_reason,''),auth.uid())
 on conflict(user_id) do update set suspended=excluded.suspended,reason=excluded.reason,updated_by=auth.uid(),updated_at=now();
 insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),case when p_suspended then 'suspend_account' else 'restore_account' end,p_target,jsonb_build_object('reason',coalesce(p_reason,'')));
end $$;
create or replace function catcul.admin_moderate(p_message_id uuid,p_report_id uuid default null,p_remove boolean default false,p_resolution text default '')
returns void language plpgsql security definer set search_path='' as $$
declare m catcul.messages;rep catcul.message_reports;
begin
 perform catcul.require_platform_admin();
 if char_length(btrim(coalesce(p_resolution,''))) not between 3 and 500 then raise exception 'Provide a moderation note of 3–500 characters.';end if;
 select * into m from catcul.messages where id=p_message_id for update;
 if not found then raise exception 'Message not found.';end if;
 if p_report_id is not null then
  select * into rep from catcul.message_reports where id=p_report_id and message_id=m.id for update;
  if not found then raise exception 'Report not found.' using errcode='42501';end if;
 elsif not exists(select 1 from catcul.rooms where id=m.room_id and purpose='community') then
  raise exception 'Private messages require a submitted report.' using errcode='42501';
 end if;
 if p_remove then
  update catcul.messages set body='',deleted_at=coalesce(deleted_at,now()),attachment_id=null where id=m.id;
  if m.attachment_id is not null then update catcul.attachments set deleted_at=now() where id=m.attachment_id;end if;
  update catcul.message_reactions set active=false where message_id=m.id;
 end if;
 if p_report_id is not null then update catcul.message_reports set status=case when p_remove then 'resolved' else 'dismissed' end,resolution=p_resolution,resolved_at=now(),resolved_by=auth.uid() where id=p_report_id;end if;
 insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),case when p_remove then 'remove_message' else 'dismiss_report' end,m.id,jsonb_build_object('report_id',p_report_id,'note',p_resolution));
end $$;
create or replace function catcul.admin_audit_log()
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform catcul.require_platform_admin();
 return coalesce((select jsonb_agg(to_jsonb(q)) from(select a.*,p.username from catcul.admin_audit a join catcul.profiles p on p.id=a.actor_id order by a.created_at desc limit 50)q),'[]'::jsonb);
end $$;

revoke all on function catcul.report_message(uuid,text,text),catcul.admin_dashboard(),catcul.admin_accounts(text,integer),catcul.admin_reports(text,integer),catcul.admin_community(integer),catcul.admin_save_school(text[],text),catcul.admin_set_account_status(uuid,boolean,text),catcul.admin_moderate(uuid,uuid,boolean,text),catcul.admin_audit_log() from public,anon,authenticated;
grant execute on function catcul.report_message(uuid,text,text),catcul.admin_dashboard(),catcul.admin_accounts(text,integer),catcul.admin_reports(text,integer),catcul.admin_community(integer),catcul.admin_save_school(text[],text),catcul.admin_set_account_status(uuid,boolean,text),catcul.admin_moderate(uuid,uuid,boolean,text),catcul.admin_audit_log() to authenticated,service_role;

-- A service-only cleanup operation for accounts just suspended by a verified admin.
create or replace function catcul.admin_suspend_calls_as(p_actor uuid,p_target uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ids uuid[];
begin
 if not exists(select 1 from catcul.platform_admins where user_id=p_actor)
  or exists(select 1 from catcul.account_controls where user_id=p_actor and suspended)
  or not exists(select 1 from catcul.account_controls where user_id=p_target and suspended) then
  raise exception 'Administrator suspension required.' using errcode='42501';end if;
 select coalesce(array_agg(c.id),'{}'::uuid[]) into ids from catcul.voice_calls c
 where (c.ended_at is null or c.ended_at>now()-interval '10 minutes')
 and exists(select 1 from catcul.call_participants p where p.call_id=c.id and p.user_id=p_target);
 update catcul.call_participants set state='left',left_at=coalesce(left_at,now()) where call_id=any(ids) and user_id=p_target;
 update catcul.voice_calls c set status='ended',ended_at=now(),ended_by=p_actor
 where c.id=any(ids) and c.ended_at is null and
 (exists(select 1 from catcul.rooms r where r.id=c.room_id and r.kind='direct')
 or not exists(select 1 from catcul.call_participants p where p.call_id=c.id and p.state='accepted' and p.last_seen_at>now()-interval '100 seconds'));
 return to_jsonb(ids);
end $$;
revoke all on function catcul.admin_suspend_calls_as(uuid,uuid) from public,anon,authenticated;
grant execute on function catcul.admin_suspend_calls_as(uuid,uuid) to service_role;

create or replace function catcul.topic_allowed(p_topic text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null then return false;end if;
 if p_topic in ('catcul:user:'||auth.uid()::text,'catcul:school:'||auth.uid()::text,'catcul:diary:'||auth.uid()::text) then return true;end if;
 if p_topic !~ '^catcul:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false;end if;
 return catcul.can_send_to_room(split_part(p_topic,':',2)::uuid);
end $$;

-- Deny suspended JWTs at the data layer, not only at the UI/sign-in screen.
create or replace function catcul.guard_account_write()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform catcul.assert_active_account();
 if tg_op='DELETE' then return old;end if;return new;
end $$;
do $$declare t record;begin
 for t in select tablename from pg_tables where schemaname='catcul' loop
  execute format('drop policy if exists student_active_account on catcul.%I',t.tablename);
  execute format('create policy student_active_account on catcul.%I as restrictive for all to authenticated using(catcul.account_is_active()) with check(catcul.account_is_active())',t.tablename);
  execute format('drop trigger if exists student_account_guard on catcul.%I',t.tablename);
  execute format('create trigger student_account_guard before insert or update or delete on catcul.%I for each row execute function catcul.guard_account_write()',t.tablename);
 end loop;
end $$;
drop policy if exists catcul_active_storage on storage.objects;
create policy catcul_active_storage on storage.objects as restrictive for all to authenticated using(bucket_id<>'catcul-media' or catcul.account_is_active()) with check(bucket_id<>'catcul-media' or catcul.account_is_active());

-- Add a guard to existing authenticated SECURITY DEFINER RPCs, which bypass RLS.
-- Their original body/return signatures remain intact. New admin/access helpers
-- are explicit and excluded. Reapply this migration last after older upgrades.
do $$declare f record;src text;def text;guard text;begin
 guard:=E'\n perform catcul.assert_active_account(); -- CATCUL_ACTIVE_GUARD\n';
 for f in select p.oid,p.proname,p.prosrc,p.proretset,p.prorettype,l.lanname
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_language l on l.oid=p.prolang
  where n.nspname='catcul' and p.prosecdef and p.provolatile<>'i' and p.prorettype<>'trigger'::regtype
  and has_function_privilege('authenticated',p.oid,'execute')
  and p.proname not in ('account_is_active','assert_active_account','is_platform_admin','require_platform_admin','get_app_access')
 loop
  if position('CATCUL_ACTIVE_GUARD' in f.prosrc)>0 then continue;end if;
  guard:=case when f.prorettype='boolean'::regtype then E'\n if auth.uid() is not null and not catcul.account_is_active() then return false;end if; -- CATCUL_ACTIVE_GUARD\n' else E'\n perform catcul.assert_active_account(); -- CATCUL_ACTIVE_GUARD\n' end;
  def:=pg_get_functiondef(f.oid);
  if f.lanname='plpgsql' then
   src:=regexp_replace(f.prosrc,'\mbegin\M','begin'||guard,'i');
  elsif f.lanname='sql' then
   src:=regexp_replace(btrim(f.prosrc),';\s*$','');
   if f.proretset then src:=E'#variable_conflict use_column\nbegin'||guard||' return query '||src||'; end';
   elsif f.prorettype='void'::regtype then continue;
   else src:=E'#variable_conflict use_column\nbegin'||guard||' return ('||src||'); end';end if;
   def:=replace(def,'LANGUAGE sql','LANGUAGE plpgsql');
  else continue;end if;
  def:=replace(def,'AS $function$'||f.prosrc||'$function$','AS $function$'||src||'$function$');
  execute def;
 end loop;
end $$;
-- Explicit actors used by managed service endpoints also honor account suspension.
do $$declare f record;src text;def text;begin
 for f in select p.oid,p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='catcul' and p.proname in ('kick_group_member_as','end_voice_call_as','check_campus_as','consume_study_request_as','consume_lesson_search_as') loop
  if position('CATCUL_ACTOR_GUARD' in f.prosrc)>0 then continue;end if;
  src:=regexp_replace(f.prosrc,'\mbegin\M',$guard$begin
 if exists(select 1 from catcul.account_controls where user_id=p_actor and suspended) then raise exception 'Account suspended.' using errcode='42501';end if; -- CATCUL_ACTOR_GUARD
$guard$,'i');
  def:=pg_get_functiondef(f.oid);
  execute replace(def,'AS $function$'||f.prosrc||'$function$','AS $function$'||src||'$function$');
 end loop;
end $$;
-- Private diary updates use a user-owned Realtime topic.
do $$begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='catcul' and tablename='diary_entries') then alter publication supabase_realtime add table catcul.diary_entries;end if;
end $$;
notify pgrst,'reload schema';
commit;
select 'Student workspace installed. Bootstrap your owner account privately; deploy catcul-admin and updated school/calls functions.' as result;
