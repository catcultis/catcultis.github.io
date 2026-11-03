-- Catcul: retire Study Mode, passcodes and campus auto-lock.
-- Run LAST, after the existing student and social-canvas upgrades.
-- Keeps accounts, chats, diaries, groups, resources, moderation and suspensions.
-- Does not delete conversations or private diary entries.
begin;

-- Neutralize legacy callers as well as the current UI. No password is required.
create or replace function catcul.study_locked()
returns boolean language sql stable security definer set search_path='' as $$ select false; $$;
create or replace function catcul.get_study_state()
returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform catcul.assert_active_account();
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 return jsonb_build_object('is_study_mode',false,'retired',true);
end $$;
create or replace function catcul.enable_study_mode()
returns jsonb language plpgsql security definer set search_path='' as $$begin
 perform catcul.assert_active_account();
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 return jsonb_build_object('is_study_mode',false,'retired',true);
end $$;
create or replace function catcul.unlock_study_mode(p_password text)
returns jsonb language plpgsql security definer set search_path='' as $$begin
 perform catcul.assert_active_account();
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 return jsonb_build_object('ok',true,'is_study_mode',false,'retired',true);
end $$;
create or replace function catcul.check_campus_as(p_actor uuid,p_ip text)
returns jsonb language plpgsql security definer set search_path='' as $$begin
 if p_actor is null or not exists(select 1 from catcul.profiles where id=p_actor)
  or exists(select 1 from catcul.account_controls where user_id=p_actor and suspended) then
  raise exception 'Active account required.' using errcode='42501';end if;
 -- Deliberately do not parse, store or match the supplied IP.
 return jsonb_build_object('is_study_mode',false,'campus_detected',false,'network_configured',false,'retired',true);
end $$;
revoke all on function catcul.study_locked(),catcul.get_study_state(),catcul.enable_study_mode(),catcul.unlock_study_mode(text),catcul.check_campus_as(uuid,text) from public,anon,authenticated;
grant execute on function catcul.study_locked(),catcul.get_study_state(),catcul.enable_study_mode(),catcul.unlock_study_mode(text) to authenticated,service_role;
grant execute on function catcul.check_campus_as(uuid,text) to service_role;

-- Old clients/service functions cannot silently relock anyone.
create or replace function catcul.retire_study_setting()
returns trigger language plpgsql set search_path='' as $$begin
 new.is_study_mode=false;new.failed_attempts=0;new.locked_until=null;
 return new;
end $$;
revoke all on function catcul.retire_study_setting() from public,anon,authenticated;
drop trigger if exists retire_study_setting on catcul.study_settings;
create trigger retire_study_setting before insert or update on catcul.study_settings for each row execute function catcul.retire_study_setting();
update catcul.study_settings set is_study_mode=false,failed_attempts=0,locked_until=null,updated_at=now();
update catcul.school_config set campus_networks='{}'::cidr[],study_password_hash='retired-no-passcode',updated_at=now() where id;

-- Remove obsolete owner-panel controls without giving students any new authority.
create or replace function catcul.admin_save_school(p_networks text[],p_new_password text default null)
returns void language plpgsql security definer set search_path='' as $$begin
 perform catcul.require_platform_admin();
 raise exception 'School locking and passcodes have been removed.' using errcode='0A000';
end $$;
create or replace function catcul.admin_dashboard()
returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform catcul.require_platform_admin();
 return jsonb_build_object('accounts',(select count(*) from catcul.profiles),
 'suspended',(select count(*) from catcul.account_controls where suspended),
 'rooms',(select count(*) from catcul.rooms),
 'messages',(select count(*) from catcul.messages where deleted_at is null),
 'reports_open',(select count(*) from catcul.message_reports where status='open'));
end $$;
create or replace function catcul.get_workspace_capabilities()
returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform catcul.assert_active_account();
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501';end if;
 return jsonb_build_object('open_workspace',true,'notes_decoy',true,'version',8);
end $$;
revoke all on function catcul.get_workspace_capabilities() from public,anon;
grant execute on function catcul.get_workspace_capabilities() to authenticated,service_role;

-- The plain notes screen makes no AI/provider requests.
revoke execute on function catcul.consume_study_request_as(uuid) from public,anon,authenticated,service_role;
-- Preserve existing function bodies/authorization while updating obsolete error text.
-- Membership/auth failures must not tell students to enter a removed passcode.
do $retire_messages$
declare f record; definition text;
begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='catcul' and p.prokind='f' and p.prosrc like '%Study Mode%'
 loop
  definition:=pg_get_functiondef(f.oid);
  definition:=replace(definition,'Community is available outside Study Mode.','Sign in to open the community.');
  definition:=replace(definition,'Unlock Study Mode with the passcode first.','Sign in with an active account first.');
  definition:=replace(definition,'Unlock Study Mode and open an accessible chat first.','Open an accessible chat first.');
  definition:=replace(definition,'Unlock Study Mode and open your room first.','Open a room you belong to first.');
  definition:=replace(definition,'Unlock Study Mode first.','Sign in with an active account first.');
  execute definition;
 end loop;
end $retire_messages$;
notify pgrst,'reload schema';
commit;
select 'Open workspace enabled. No Study Mode password, IP lock or social restrictions. Account suspensions and room privacy remain enforced.' as result;
