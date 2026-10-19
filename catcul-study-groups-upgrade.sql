-- Catcul: invite-only study groups. Run AFTER catcul-school-upgrade.sql.
-- Rerunnable. No data deletion and no changes to passcodes/campus networks.
begin;
alter table catcul.rooms add column if not exists is_study_group boolean not null default false;
alter table catcul.rooms drop constraint if exists study_groups_are_academic;
alter table catcul.rooms add constraint study_groups_are_academic
  check(not is_study_group or (purpose='course' and kind='group'));

-- Academic groups reuse course membership/RLS, invite expiry, resources,
-- homework and voice rules. They are NOT publicly joinable community rooms.
create or replace function catcul.create_study_group(p_name text,p_subject text default '')
returns catcul.rooms language plpgsql security definer set search_path='' as $$
declare r catcul.rooms;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  if p_name is null or char_length(btrim(p_name)) not between 1 and 40
    or char_length(coalesce(p_subject,''))>16 then
    raise exception 'Use a group name up to 40 characters and subject up to 16.';
  end if;
  select * into r from catcul.create_course(p_name,coalesce(p_subject,''));
  update catcul.rooms set is_study_group=true where id=r.id returning * into r;
  return r;
end $$;

-- Additive RPC preserves the existing list_workspace_spaces return type.
create or replace function catcul.list_study_spaces()
returns table(id uuid,name text,kind text,role text,peer_id uuid,peer_name text,peer_color text,
  can_send boolean,last_read_at timestamptz,unread_count bigint,last_body text,last_kind text,
  last_message_at timestamptz,purpose text,course_code text,is_study_group boolean)
language sql stable security definer set search_path='' as $$
 select s.*,r.is_study_group from catcul.list_workspace_spaces() s
 join catcul.rooms r on r.id=s.id where catcul.is_member(s.id);
$$;
revoke all on function catcul.create_study_group(text,text),catcul.list_study_spaces() from public,anon,authenticated;
grant execute on function catcul.create_study_group(text,text),catcul.list_study_spaces() to authenticated,service_role;
notify pgrst,'reload schema';
commit;
select 'Invite-only study groups installed. Existing course security applies.' as result;
