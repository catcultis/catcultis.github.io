-- Catcul Chat Tools Upgrade
-- Adds: per-user chat pin/archive/mark-unread/notification prefs, custom labels & wallpapers,
-- message editing with history, file documents (PDF/DOC/PPT/XLS/TXT/CSV/ZIP), pinned messages,
-- owner group controls (posting/media/files/approvals/join approval/auto-archive/retention),
-- join requests, ownership transfer, room merge (member move + archive source), scheduled sweeps.
-- Run AFTER catcul-open-workspace-upgrade.sql. Idempotent: safe to run twice.

begin;
create schema if not exists catcul;

-- ---------- Generic rate limiter (security definer functions use it; no direct user access) ----------
create table if not exists catcul.rate_limits (
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  action text not null check (char_length(action) between 3 and 40),
  window_start timestamptz not null,
  count integer not null default 0,
  primary key (user_id, action, window_start)
);
alter table catcul.rate_limits enable row level security;
revoke all on catcul.rate_limits from public, anon, authenticated;

create or replace function catcul.consume_rate(p_action text, p_limit integer, p_seconds integer)
returns void language plpgsql security definer set search_path='' as $$
declare v_window timestamptz := to_timestamp(floor(extract(epoch from now()) / p_seconds) * p_seconds);
begin
  insert into catcul.rate_limits(user_id, action, window_start, count)
  values (auth.uid(), p_action, v_window, 1)
  on conflict (user_id, action, window_start) do update set count = catcul.rate_limits.count + 1;
  if (select count from catcul.rate_limits where user_id=auth.uid() and action=p_action and window_start=v_window) > p_limit then
    raise exception 'Too many attempts. Please try again later.' using errcode='54000';
  end if;
end $$;

-- ---------- App-wide admin setting ----------
create table if not exists catcul.app_settings (
  key text primary key check (key ~ '^[a-z_]{3,40}$'),
  value jsonb not null default 'false'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into catcul.app_settings(key,value) values('admin_can_read_edit_history','false'::jsonb) on conflict (key) do nothing;
alter table catcul.app_settings enable row level security;
revoke all on catcul.app_settings from public, anon;
drop policy if exists app_settings_admin_read on catcul.app_settings;
create policy app_settings_admin_read on catcul.app_settings for select to authenticated using (catcul.is_platform_admin());
grant select on catcul.app_settings to authenticated;

create or replace function catcul.set_chat_admin_setting(p_key text, p_enabled boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform catcul.require_platform_admin();
  if p_key not in ('admin_can_read_edit_history') then raise exception 'Unknown setting.'; end if;
  insert into catcul.app_settings(key,value,updated_at,updated_by) values(p_key,to_jsonb(p_enabled),now(),auth.uid())
  on conflict (key) do update set value=excluded.value, updated_at=now(), updated_by=auth.uid();
  insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),'chat_setting',null,jsonb_build_object('key',p_key,'enabled',p_enabled)) on conflict do nothing;
exception when undefined_table then null; when others then
  if sqlerrm not like 'Unknown%' then raise; end if;
end $$;

create or replace function catcul.get_chat_admin_settings()
returns jsonb language sql stable security definer set search_path='' as $$
  select case when catcul.is_platform_admin()
    then coalesce((select jsonb_object_agg(key,value) from catcul.app_settings),'{}'::jsonb)
    else '{}'::jsonb end;
$$;

-- ---------- Per-user chat preferences ----------
create table if not exists catcul.room_chat_preferences (
  room_id uuid not null references catcul.rooms(id) on delete cascade,
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  pinned_at timestamptz,
  archived_at timestamptz,
  unread_mark boolean not null default false,
  notify_mode text not null default 'all' check (notify_mode in ('all','mentions','muted')),
  muted_until timestamptz,
  show_previews boolean not null default true,
  wallpaper text check (wallpaper is null or wallpaper in ('plain','mint','sand','rose','sky','night')),
  custom_label text check (custom_label is null or char_length(custom_label) between 1 and 80),
  updated_at timestamptz not null default now(),
  primary key (room_id, user_id)
);
create index if not exists chat_prefs_by_user on catcul.room_chat_preferences(user_id);
alter table catcul.room_chat_preferences enable row level security;
revoke all on catcul.room_chat_preferences from public, anon;
drop policy if exists chat_prefs_select on catcul.room_chat_preferences;
create policy chat_prefs_select on catcul.room_chat_preferences for select to authenticated using (user_id=(select auth.uid()));
drop policy if exists chat_prefs_insert on catcul.room_chat_preferences;
create policy chat_prefs_insert on catcul.room_chat_preferences for insert to authenticated with check (user_id=(select auth.uid()) and catcul.is_member(room_id));
drop policy if exists chat_prefs_update on catcul.room_chat_preferences;
create policy chat_prefs_update on catcul.room_chat_preferences for update to authenticated using (user_id=(select auth.uid())) with check (user_id=(select auth.uid()));
drop policy if exists chat_prefs_delete on catcul.room_chat_preferences;
create policy chat_prefs_delete on catcul.room_chat_preferences for delete to authenticated using (user_id=(select auth.uid()));
grant select, insert, update, delete on catcul.room_chat_preferences to authenticated;

create or replace function catcul.set_room_pin(p_room_id uuid, p_pinned boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode='42501'; end if;
  if p_pinned and (select count(*) from catcul.room_chat_preferences where user_id=auth.uid() and pinned_at is not null and room_id<>p_room_id) >= 5
    then raise exception 'You can pin up to 5 chats.'; end if;
  insert into catcul.room_chat_preferences(room_id,user_id,pinned_at) values(p_room_id,auth.uid(),case when p_pinned then now() end)
  on conflict (room_id,user_id) do update set pinned_at=excluded.pinned_at, updated_at=now();
end $$;

create or replace function catcul.set_room_archive(p_room_id uuid, p_archived boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode='42501'; end if;
  insert into catcul.room_chat_preferences(room_id,user_id,archived_at,pinned_at) values(p_room_id,auth.uid(),case when p_archived then now() end, null)
  on conflict (room_id,user_id) do update set archived_at=excluded.archived_at, pinned_at=null, updated_at=now();
end $$;

create or replace function catcul.set_room_unread_mark(p_room_id uuid, p_marked boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode='42501'; end if;
  insert into catcul.room_chat_preferences(room_id,user_id,unread_mark) values(p_room_id,auth.uid(),p_marked)
  on conflict (room_id,user_id) do update set unread_mark=excluded.unread_mark, updated_at=now();
end $$;

create or replace function catcul.set_room_notifications(p_room_id uuid, p_mode text, p_muted_until timestamptz, p_show_previews boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode='42501'; end if;
  if p_mode not in ('all','mentions','muted') then raise exception 'Unknown notification mode.'; end if;
  if p_muted_until is not null and p_muted_until > now() + interval '370 days' then p_muted_until := null; end if;
  insert into catcul.room_chat_preferences(room_id,user_id,notify_mode,muted_until,show_previews)
  values(p_room_id,auth.uid(),p_mode,case when p_mode='muted' then p_muted_until end,p_show_previews)
  on conflict (room_id,user_id) do update set notify_mode=excluded.notify_mode, muted_until=excluded.muted_until, show_previews=excluded.show_previews, updated_at=now();
end $$;

create or replace function catcul.set_room_personalization(p_room_id uuid, p_wallpaper text, p_label text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode='42501'; end if;
  if p_label is not null and char_length(btrim(p_label))=0 then p_label:=null; end if;
  insert into catcul.room_chat_preferences(room_id,user_id,wallpaper,custom_label) values(p_room_id,auth.uid(),p_wallpaper,left(p_label,80))
  on conflict (room_id,user_id) do update set wallpaper=excluded.wallpaper, custom_label=excluded.custom_label, updated_at=now();
end $$;

-- Superset room list for the updated frontend.
create or replace function catcul.list_chat_spaces()
returns table(id uuid,name text,kind text,role text,peer_id uuid,peer_name text,peer_color text,
  can_send boolean,last_read_at timestamptz,unread_count bigint,last_body text,last_kind text,
  last_message_at timestamptz,purpose text,course_code text,is_study_group boolean,
  pinned_at timestamptz,archived_at timestamptz,unread_mark boolean,notify_mode text,muted_until timestamptz,
  show_previews boolean,wallpaper text,custom_label text)
language sql stable security definer set search_path='' as $$
  select s.id,s.name,s.kind,s.role,s.peer_id,s.peer_name,s.peer_color,s.can_send,s.last_read_at,s.unread_count,
         s.last_body,s.last_kind,s.last_message_at,s.purpose,s.course_code,s.is_study_group,
         p.pinned_at,p.archived_at,coalesce(p.unread_mark,false),coalesce(p.notify_mode,'all'),p.muted_until,
         coalesce(p.show_previews,true),p.wallpaper,p.custom_label
  from catcul.list_study_spaces() s
  left join catcul.room_chat_preferences p on p.room_id=s.id and p.user_id=(select auth.uid());
$$;

-- ---------- Message editing ----------
alter table catcul.messages add column if not exists edited_at timestamptz;
alter table catcul.messages add column if not exists approved boolean not null default true;

create table if not exists catcul.message_edits (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null,
  room_id uuid not null,
  editor_id uuid not null default auth.uid() references catcul.profiles(id),
  old_body text not null default '' check (char_length(old_body) <= 4000),
  new_body text not null check (char_length(btrim(new_body)) between 1 and 4000),
  edited_at timestamptz not null default now(),
  foreign key (message_id, room_id) references catcul.messages(id, room_id) on delete cascade
);
create index if not exists message_edits_by_message on catcul.message_edits(message_id, edited_at desc);
alter table catcul.message_edits enable row level security;
revoke all on catcul.message_edits from public, anon;
drop policy if exists message_edits_select on catcul.message_edits;
create policy message_edits_select on catcul.message_edits for select to authenticated using (
  editor_id=(select auth.uid())
  or (catcul.is_platform_admin() and coalesce((select (value)::boolean from catcul.app_settings where key='admin_can_read_edit_history'),false))
);
grant select on catcul.message_edits to authenticated;

create or replace function catcul.edit_message(p_message_id uuid, p_body text)
returns timestamptz language plpgsql security definer set search_path='' as $$
declare v catcul.messages; v_room catcul.rooms; v_now timestamptz := now();
begin
  perform catcul.consume_rate('edit_message', 30, 3600);
  select * into v from catcul.messages where id=p_message_id for update;
  if not found then raise exception 'Message not found.' using errcode='P0002'; end if;
  select * into v_room from catcul.rooms where id=v.room_id;
  if v_room.archived_at is not null then raise exception 'This room has been archived.'; end if;
  if v.deleted_at is not null then raise exception 'This message was removed.'; end if;
  if v.kind not in ('text','file') then raise exception 'Only text and document captions can be edited.'; end if;
  if v.sender_id is distinct from auth.uid() then raise exception 'You can only edit your own messages.' using errcode='42501'; end if;
  if v.created_at < v_now - interval '24 hours' then raise exception 'Messages can be edited within 24 hours of sending.'; end if;
  if p_body is null or char_length(btrim(p_body))=0 or char_length(p_body)>4000 then raise exception 'Message needs 1-4000 characters.'; end if;
  if p_body = v.body then raise exception 'Nothing changed.'; end if;
  insert into catcul.message_edits(message_id,room_id,old_body,new_body) values(v.id,v.room_id,v.body,left(p_body,4000));
  update catcul.messages set body=left(p_body,4000), edited_at=v_now where id=p_message_id;
  return v_now;
end $$;

-- ---------- File documents ----------
do $$
declare r record;
begin
  for r in select c.conname from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
    where n.nspname='catcul' and t.relname='messages' and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%kind%' loop
    execute format('alter table catcul.messages drop constraint %I', r.conname);
  end loop;
  for r in select c.conname from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
    where n.nspname='catcul' and t.relname='messages' and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%deleted_at is not null%' loop
    execute format('alter table catcul.messages drop constraint %I', r.conname);
  end loop;
  for r in select c.conname from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
    where n.nspname='catcul' and t.relname='attachments' and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%mime_type%' loop
    execute format('alter table catcul.attachments drop constraint %I', r.conname);
  end loop;
  for r in select c.conname from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
    where n.nspname='catcul' and t.relname='attachments' and c.contype='c' and (pg_get_constraintdef(c.oid) ilike '%byte_size%' or pg_get_constraintdef(c.oid) ilike '%file_name%') loop
    execute format('alter table catcul.attachments drop constraint %I', r.conname);
  end loop;
end $$;

alter table catcul.messages add constraint messages_kind_check check (kind in ('text','photo','audio','file'));
alter table catcul.messages add constraint messages_content_check check (
  deleted_at is not null or (
    (kind = 'text' and char_length(btrim(body)) > 0 and attachment_id is null)
    or (kind in ('photo','audio','file') and attachment_id is not null)
  )
);

alter table catcul.attachments add column if not exists file_name text;
alter table catcul.attachments add constraint attachments_mime_check check (mime_type in (
  'image/jpeg','image/png','image/webp','audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav',
  'application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'text/plain','text/csv','application/zip','application/x-zip-compressed'));
alter table catcul.attachments add constraint attachments_size_check check (byte_size between 1 and 26214400);
alter table catcul.attachments add constraint attachments_file_name_check check (file_name is null or char_length(file_name) between 1 and 200);
grant insert(file_name) on catcul.attachments to authenticated;

-- Extend the message-insert policy so kind='file' can carry a document attachment.
create or replace function catcul.is_document_mime(p_mime text)
returns boolean language sql immutable set search_path='' as $$
  select p_mime in ('application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/plain','text/csv','application/zip','application/x-zip-compressed');
$$;
grant execute on function catcul.is_document_mime(text) to authenticated;
drop policy if exists catcul_messages_insert on catcul.messages;
create policy catcul_messages_insert on catcul.messages for insert to authenticated with check (
  sender_id=(select auth.uid()) and deleted_at is null and catcul.can_send_to_room(room_id)
  and (reply_to is null or exists(select 1 from catcul.messages parent where parent.id=messages.reply_to and parent.room_id=messages.room_id))
  and (attachment_id is null or exists(select 1 from catcul.attachments a
       where a.id=messages.attachment_id and a.room_id=messages.room_id and a.uploaded_by=(select auth.uid()) and a.deleted_at is null
         and (((messages.kind='photo') and a.mime_type like 'image/%')
           or ((messages.kind='audio') and a.mime_type like 'audio/%')
           or ((messages.kind='file') and catcul.is_document_mime(a.mime_type)))))
);

update storage.buckets set file_size_limit=26214400,
  allowed_mime_types=array['image/jpeg','image/png','image/webp','audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav',
    'application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/plain','text/csv','application/zip']
where id='catcul-media';

-- ---------- Pinned messages ----------
create table if not exists catcul.pinned_messages (
  room_id uuid not null,
  message_id uuid not null,
  pinned_by uuid not null default auth.uid() references catcul.profiles(id),
  pinned_at timestamptz not null default now(),
  primary key (room_id, message_id),
  foreign key (message_id, room_id) references catcul.messages(id, room_id) on delete cascade
);
alter table catcul.pinned_messages enable row level security;
revoke all on catcul.pinned_messages from public, anon;
drop policy if exists pinned_read on catcul.pinned_messages;
create policy pinned_read on catcul.pinned_messages for select to authenticated using (catcul.is_member(room_id));
grant select on catcul.pinned_messages to authenticated;

create or replace function catcul.is_room_moderator(p_room_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from catcul.room_members where room_id=p_room_id and user_id=(select auth.uid()) and removed_at is null and role in ('owner','admin'));
$$;

create or replace function catcul.pin_message(p_room_id uuid, p_message_id uuid, p_pinned boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not catcul.is_room_moderator(p_room_id) then raise exception 'Only group owners and admins can pin messages.' using errcode='42501'; end if;
  if not exists(select 1 from catcul.messages where id=p_message_id and room_id=p_room_id and deleted_at is null) then raise exception 'Message not found.' using errcode='P0002'; end if;
  if p_pinned then
    if (select count(*) from catcul.pinned_messages where room_id=p_room_id) >= 3 then raise exception 'Up to 3 pinned messages per room.'; end if;
    insert into catcul.pinned_messages(room_id,message_id) values(p_room_id,p_message_id) on conflict do nothing;
  else
    delete from catcul.pinned_messages where room_id=p_room_id and message_id=p_message_id;
  end if;
end $$;

-- ---------- Room lifecycle columns & controls ----------
alter table catcul.rooms add column if not exists archived_at timestamptz;
alter table catcul.rooms add column if not exists posting_mode text not null default 'everyone';
alter table catcul.rooms add column if not exists allow_media boolean not null default true;
alter table catcul.rooms add column if not exists allow_files boolean not null default true;
alter table catcul.rooms add column if not exists require_message_approval boolean not null default false;
alter table catcul.rooms add column if not exists join_approval boolean not null default false;
alter table catcul.rooms add column if not exists auto_archive_at timestamptz;
alter table catcul.rooms add column if not exists message_retention_days integer;
do $$
declare r record;
begin
  for r in select c.conname from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
    where n.nspname='catcul' and t.relname='rooms' and c.contype='c' and (pg_get_constraintdef(c.oid) ilike '%posting_mode%' or pg_get_constraintdef(c.oid) ilike '%message_retention%') loop
    execute format('alter table catcul.rooms drop constraint %I', r.conname);
  end loop;
end $$;
alter table catcul.rooms add constraint rooms_posting_mode_check check (posting_mode in ('everyone','admins'));
alter table catcul.rooms add constraint rooms_retention_check check (message_retention_days is null or message_retention_days between 1 and 365);

create or replace function catcul.room_settings(p_room_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
  select case when catcul.is_member(p_room_id) then (
    select jsonb_build_object('archived',r.archived_at is not null,'archived_at',r.archived_at,'posting_mode',r.posting_mode,
      'allow_media',r.allow_media,'allow_files',r.allow_files,'require_message_approval',r.require_message_approval,
      'join_approval',r.join_approval,'auto_archive_at',r.auto_archive_at,'message_retention_days',r.message_retention_days)
    from catcul.rooms r where r.id=p_room_id) else '{}'::jsonb end;
$$;

-- Room admins supported alongside owners.
do $$
declare r record;
begin
  for r in select c.conname from pg_constraint c join pg_class t on t.oid=c.conrelid join pg_namespace n on n.oid=t.relnamespace
    where n.nspname='catcul' and t.relname='room_members' and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%role%' loop
    execute format('alter table catcul.room_members drop constraint %I', r.conname);
  end loop;
end $$;
alter table catcul.room_members add constraint room_members_role_check check (role in ('owner','admin','member'));

create or replace function catcul.require_room_owner(p_room_id uuid)
returns void language plpgsql stable security definer set search_path='' as $$
begin
  if not exists(select 1 from catcul.room_members where room_id=p_room_id and user_id=auth.uid() and removed_at is null and role='owner')
    then raise exception 'Only the group owner can do that.' using errcode='42501'; end if;
end $$;

create or replace function catcul.set_group_controls(p_room_id uuid, p_posting_mode text, p_allow_media boolean, p_allow_files boolean,
  p_require_approval boolean, p_join_approval boolean, p_auto_archive_at timestamptz, p_retention_days integer)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform catcul.consume_rate('group_controls', 30, 3600);
  perform catcul.require_room_owner(p_room_id);
  if p_posting_mode not in ('everyone','admins') then raise exception 'Unknown posting mode.'; end if;
  if p_retention_days is not null and p_retention_days not between 1 and 365 then raise exception 'Retention must be 1-365 days.'; end if;
  update catcul.rooms set posting_mode=p_posting_mode, allow_media=p_allow_media, allow_files=p_allow_files,
    require_message_approval=p_require_approval, join_approval=p_join_approval, auto_archive_at=p_auto_archive_at,
    message_retention_days=p_retention_days where id=p_room_id;
  insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),'group_controls',p_room_id,
    jsonb_build_object('posting_mode',p_posting_mode,'approval',p_require_approval,'join_approval',p_join_approval));
end $$;

create or replace function catcul.archive_room(p_room_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform catcul.require_room_owner(p_room_id);
  update catcul.rooms set archived_at=now() where id=p_room_id and archived_at is null;
  insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),'archive_room',p_room_id,'{}'::jsonb);
end $$;

create or replace function catcul.transfer_room_ownership(p_room_id uuid, p_new_owner uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform catcul.consume_rate('transfer_room', 6, 3600);
  perform catcul.require_room_owner(p_room_id);
  if p_new_owner = auth.uid() then raise exception 'You already own this room.'; end if;
  if not exists(select 1 from catcul.room_members where room_id=p_room_id and user_id=p_new_owner and removed_at is null)
    then raise exception 'The new owner must be a member of this room.'; end if;
  update catcul.room_members set role='admin' where room_id=p_room_id and user_id=auth.uid() and removed_at is null;
  update catcul.room_members set role='owner' where room_id=p_room_id and user_id=p_new_owner and removed_at is null;
  insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),'transfer_room',p_room_id,jsonb_build_object('new_owner',p_new_owner));
end $$;

create or replace function catcul.claim_abandoned_room(p_room_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_next uuid;
begin
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode='42501'; end if;
  if exists(select 1 from catcul.room_members where room_id=p_room_id and removed_at is null and role='owner')
    then raise exception 'This room already has an owner.'; end if;
  select user_id into v_next from catcul.room_members where room_id=p_room_id and removed_at is null order by joined_at, user_id limit 1;
  if v_next is distinct from auth.uid() then raise exception 'Only the longest-standing member can claim this room.' using errcode='42501'; end if;
  update catcul.room_members set role='owner' where room_id=p_room_id and user_id=v_next;
  insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),'claim_room',p_room_id,'{}'::jsonb);
end $$;

create or replace function catcul.merge_rooms(p_source uuid, p_target uuid)
returns integer language plpgsql security definer set search_path='' as $$
declare v_moved integer := 0; v_name text;
begin
  perform catcul.consume_rate('merge_rooms', 6, 86400);
  if p_source = p_target then raise exception 'Choose two different rooms.'; end if;
  perform catcul.require_room_owner(p_source);
  perform catcul.require_room_owner(p_target);
  if exists(select 1 from catcul.rooms where id in (p_source,p_target) and (purpose in ('course','community') or kind='direct'))
    then raise exception 'Only regular groups can be merged.'; end if;
  if exists(select 1 from catcul.rooms where id=p_target and archived_at is not null) then raise exception 'The destination room is archived.'; end if;
  select name into v_name from catcul.rooms where id=p_source;
  with moved as (
    insert into catcul.room_members(room_id,user_id,role)
      select p_target, user_id, 'member' from catcul.room_members
      where room_id=p_source and removed_at is null
        and not exists(select 1 from catcul.room_members t where t.room_id=p_target and t.user_id=room_members.user_id and t.removed_at is null)
    returning user_id)
  select count(*) into v_moved from moved;
  update catcul.rooms set archived_at=now() where id=p_source and archived_at is null;
  update catcul.room_invites set revoked_at=now() where room_id=p_source and revoked_at is null;
  insert into catcul.messages(room_id,sender_id,body,kind) values(p_target,auth.uid(),
    'Merged "' || left(v_name,100) || '" into this room. ' || v_moved || ' member(s) joined from it.','text');
  insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),'merge_rooms',p_target,jsonb_build_object('source',p_source,'moved',v_moved));
  return v_moved;
end $$;

-- ---------- Join requests ----------
create table if not exists catcul.room_join_requests (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references catcul.rooms(id) on delete cascade,
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','approved','denied')),
  decided_by uuid,
  decided_at timestamptz,
  unique (room_id, user_id)
);
alter table catcul.room_join_requests enable row level security;
revoke all on catcul.room_join_requests from public, anon;
drop policy if exists join_requests_select on catcul.room_join_requests;
create policy join_requests_select on catcul.room_join_requests for select to authenticated using (
  user_id=(select auth.uid()) or catcul.is_room_moderator(room_id));
grant select on catcul.room_join_requests to authenticated;

create or replace function catcul.request_join_room(p_token text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_user uuid := auth.uid(); v_invite catcul.room_invites; v_room catcul.rooms;
begin
  if v_user is null then raise exception 'Sign in first.' using errcode='42501'; end if;
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then raise exception 'Invalid invitation.'; end if;
  perform catcul.ensure_profile();
  select * into v_invite from catcul.room_invites where token_hash = encode(sha256(convert_to(p_token,'UTF8')),'hex') for update;
  if not found or v_invite.revoked_at is not null or v_invite.expires_at <= now() or v_invite.uses >= v_invite.max_uses
    then raise exception 'This invitation is invalid, expired, revoked, or full.'; end if;
  select * into v_room from catcul.rooms where id=v_invite.room_id;
  if catcul.is_member(v_room.id) then return jsonb_build_object('status','member','room_id',v_room.id); end if;
  if v_room.archived_at is not null then raise exception 'This room has been archived.'; end if;
  perform catcul.consume_rate('join_request', 20, 86400);
  if v_room.join_approval then
    delete from catcul.room_join_requests where room_id=v_room.id and user_id=v_user and status='approved';
    insert into catcul.room_join_requests(room_id,user_id) values(v_room.id,v_user)
    on conflict (room_id,user_id) do update set status='pending', decided_by=null, decided_at=null, created_at=now();
    return jsonb_build_object('status','pending','room_id',v_room.id);
  end if;
  perform 1 from catcul.profiles where id = v_user for update;
  if (select count(*) from catcul.room_members where user_id = v_user) >= 50 then raise exception 'Maximum 50 rooms per account.'; end if;
  insert into catcul.room_members(room_id,user_id) values(v_room.id,v_user);
  update catcul.room_invites set uses = uses+1 where id = v_invite.id;
  return jsonb_build_object('status','joined','room_id',v_room.id);
end $$;

create or replace function catcul.respond_join_request(p_room_id uuid, p_user_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path='' as $$
declare v_req catcul.room_join_requests;
begin
  perform catcul.consume_rate('respond_join', 60, 3600);
  if not catcul.is_room_moderator(p_room_id) then raise exception 'Only group owners and admins can answer requests.' using errcode='42501'; end if;
  select * into v_req from catcul.room_join_requests where room_id=p_room_id and user_id=p_user_id and status='pending' for update;
  if not found then raise exception 'No pending request from that person.'; end if;
  update catcul.room_join_requests set status=case when p_approve then 'approved' else 'denied' end, decided_by=auth.uid(), decided_at=now()
    where id=v_req.id;
  if p_approve then insert into catcul.room_members(room_id,user_id) values(p_room_id,p_user_id) on conflict do nothing; end if;
end $$;

-- ---------- Message approval queue ----------
create or replace function catcul.list_pending_messages(p_room_id uuid)
returns setof catcul.messages language sql stable security definer set search_path='' as $$
  select m.* from catcul.messages m
  where m.room_id=p_room_id and m.approved=false and m.deleted_at is null and catcul.is_room_moderator(p_room_id)
  order by m.created_at asc limit 50;
$$;

create or replace function catcul.approve_message(p_message_id uuid, p_approve boolean)
returns void language plpgsql security definer set search_path='' as $$
declare v catcul.messages;
begin
  perform catcul.consume_rate('approve_message', 60, 3600);
  select * into v from catcul.messages where id=p_message_id for update;
  if not found then raise exception 'Message not found.' using errcode='P0002'; end if;
  if not catcul.is_room_moderator(v.room_id) then raise exception 'Only group owners and admins can approve messages.' using errcode='42501'; end if;
  if p_approve then update catcul.messages set approved=true where id=p_message_id;
  else update catcul.messages set deleted_at=now(), body='', attachment_id=null where id=p_message_id; end if;
  insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),case when p_approve then 'approve_message' else 'reject_message' end,v.room_id,jsonb_build_object('message',p_message_id));
end $$;

-- Message insert enforcement + default approval state.
create or replace function catcul.guard_room_message()
returns trigger language plpgsql security definer set search_path='' as $$
declare r catcul.rooms; v_role text;
begin
  select * into r from catcul.rooms where id=new.room_id;
  if not found then return new; end if;
  if r.archived_at is not null then raise exception 'This room has been archived and is read-only.'; end if;
  select role into v_role from catcul.room_members where room_id=new.room_id and user_id=new.sender_id and removed_at is null;
  if r.posting_mode='admins' and coalesce(v_role,'') not in ('owner','admin') then
    raise exception 'Only the group admins can post in this room.' using errcode='42501'; end if;
  if new.kind='file' and not r.allow_files then raise exception 'Files are turned off in this room.'; end if;
  if new.kind in ('photo','audio') and not r.allow_media then raise exception 'Photos and voice notes are turned off in this room.'; end if;
  new.approved := not (r.require_message_approval and coalesce(v_role,'') not in ('owner','admin'));
  return new;
end $$;
drop trigger if exists rooms_message_guard on catcul.messages;
create trigger rooms_message_guard before insert on catcul.messages for each row execute function catcul.guard_room_message();

-- Pending messages visible only to their sender and moderators. Wrapped in a single
-- security-definer helper so policy expansion never recurses into the messages table.
create or replace function catcul.message_visible(p_room_id uuid, p_sender_id uuid, p_approved boolean)
returns boolean language sql stable security definer set search_path='' as $$
  select catcul.is_member(p_room_id)
    and (p_approved or p_sender_id=(select auth.uid())
         or exists(select 1 from catcul.room_members
                   where room_id=p_room_id and user_id=(select auth.uid()) and removed_at is null and role in ('owner','admin')));
$$;
drop policy if exists catcul_messages_read on catcul.messages;
create policy catcul_messages_read on catcul.messages for select to authenticated using (catcul.message_visible(room_id,sender_id,approved));

-- ---------- Scheduled sweeps (auto-archive + retention) ----------
create or replace function catcul.sweep_my_rooms()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_archived integer := 0; v_pruned integer := 0;
begin
  with done as (
    update catcul.rooms set archived_at=now()
    where auto_archive_at is not null and auto_archive_at <= now() and archived_at is null
      and id in (select room_id from catcul.room_members where user_id=auth.uid() and removed_at is null)
    returning id)
  select count(*) into v_archived from done;
  with done as (
    update catcul.messages m set deleted_at=now()
    where m.deleted_at is null and exists(
      select 1 from catcul.rooms r where r.id=m.room_id and r.message_retention_days is not null
        and m.created_at < now() - make_interval(days => r.message_retention_days)
        and exists(select 1 from catcul.room_members mm where mm.room_id=r.id and mm.user_id=auth.uid() and mm.removed_at is null))
    returning m.id)
  select count(*) into v_pruned from done;
  return jsonb_build_object('archived',v_archived,'pruned',v_pruned);
end $$;

-- ---------- Grants ----------
revoke all on function catcul.consume_rate(text,integer,integer),catcul.set_chat_admin_setting(text,boolean),catcul.get_chat_admin_settings(),
  catcul.set_room_pin(uuid,boolean),catcul.set_room_archive(uuid,boolean),catcul.set_room_unread_mark(uuid,boolean),
  catcul.set_room_notifications(uuid,text,timestamptz,boolean),catcul.set_room_personalization(uuid,text,text),
  catcul.list_chat_spaces(),catcul.edit_message(uuid,text),catcul.is_room_moderator(uuid),catcul.pin_message(uuid,uuid,boolean),
  catcul.room_settings(uuid),catcul.require_room_owner(uuid),catcul.set_group_controls(uuid,text,boolean,boolean,boolean,boolean,timestamptz,integer),
  catcul.archive_room(uuid),catcul.transfer_room_ownership(uuid,uuid),catcul.claim_abandoned_room(uuid),catcul.merge_rooms(uuid,uuid),
  catcul.request_join_room(text),catcul.respond_join_request(uuid,uuid,boolean),catcul.list_pending_messages(uuid),catcul.approve_message(uuid,boolean),
  catcul.sweep_my_rooms(),catcul.message_visible(uuid,uuid,boolean) from public, anon;
grant execute on function catcul.set_chat_admin_setting(text,boolean),catcul.get_chat_admin_settings(),
  catcul.set_room_pin(uuid,boolean),catcul.set_room_archive(uuid,boolean),catcul.set_room_unread_mark(uuid,boolean),
  catcul.set_room_notifications(uuid,text,timestamptz,boolean),catcul.set_room_personalization(uuid,text,text),
  catcul.list_chat_spaces(),catcul.edit_message(uuid,text),catcul.is_room_moderator(uuid),catcul.pin_message(uuid,uuid,boolean),
  catcul.room_settings(uuid),catcul.set_group_controls(uuid,text,boolean,boolean,boolean,boolean,timestamptz,integer),
  catcul.archive_room(uuid),catcul.transfer_room_ownership(uuid,uuid),catcul.claim_abandoned_room(uuid),catcul.merge_rooms(uuid,uuid),
  catcul.request_join_room(text),catcul.respond_join_request(uuid,uuid,boolean),catcul.list_pending_messages(uuid),catcul.approve_message(uuid,boolean),
  catcul.sweep_my_rooms(),catcul.message_visible(uuid,uuid,boolean) to authenticated;
revoke execute on function catcul.consume_rate(text,integer,integer) from authenticated;

notify pgrst,'reload schema';
commit;
select 'Chat tools installed: pins, archive, unread marks, notification prefs, editing, files, pinned messages, group controls, join requests, lifecycle.' as result;
