-- Catcul together: room-scoped shared drawing and server-scheduled text messages.
-- Applied to the connected project. Do not rerun as a general installation script.
create table if not exists catcul.room_drawing_strokes (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references catcul.rooms(id) on delete cascade,
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  color text not null check (color ~ '^#[0-9a-fA-F]{6}$'),
  width smallint not null check (width between 2 and 18),
  points jsonb not null,
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists room_drawing_strokes_order on catcul.room_drawing_strokes(room_id,created_at,id);
alter table catcul.room_drawing_strokes enable row level security;
revoke all on catcul.room_drawing_strokes from public, anon, authenticated;
grant all on catcul.room_drawing_strokes to service_role;

create or replace function catcul.get_room_drawing(p_room uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  perform catcul.assert_active_account();
  if auth.uid() is null or not catcul.can_send_to_room(p_room) then raise exception 'Room access required.' using errcode='42501'; end if;
  if not exists(select 1 from catcul.rooms where id=p_room and purpose <> 'community') then raise exception 'Drawing is available in private and group chats.' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'color',color,'width',width,'points',points) order by created_at,id) from catcul.room_drawing_strokes where room_id=p_room),'[]'::jsonb);
end $$;

create or replace function catcul.add_room_drawing_stroke(p_room uuid,p_color text,p_width integer,p_points jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  perform catcul.assert_active_account();
  if auth.uid() is null or not catcul.can_send_to_room(p_room) or not exists(select 1 from catcul.rooms where id=p_room and purpose <> 'community' and archived_at is null) then raise exception 'Room access required.' using errcode='42501'; end if;
  if p_color is null or p_color !~ '^#[0-9a-fA-F]{6}$' or p_width is null or p_width not between 2 and 18 or p_points is null or jsonb_typeof(p_points)<>'array' or jsonb_array_length(p_points) not between 1 and 160 or pg_column_size(p_points)>10000 then raise exception 'Invalid drawing stroke.'; end if;
  if exists(select 1 from jsonb_array_elements(p_points) p where jsonb_typeof(p)<>'array' or case when jsonb_typeof(p)='array' then jsonb_array_length(p)<>2 or jsonb_typeof(p->0)<>'number' or jsonb_typeof(p->1)<>'number' else true end) then raise exception 'Invalid drawing points.'; end if;
  if exists(select 1 from jsonb_array_elements(p_points) p where (p->>0)::numeric not between 0 and 1 or (p->>1)::numeric not between 0 and 1) then raise exception 'Drawing points out of range.'; end if;
  perform catcul.consume_rate('room_drawing',300,60);
  perform pg_advisory_xact_lock(hashtextextended('drawing:'||p_room::text,0));
  if (select count(*) from catcul.room_drawing_strokes where room_id=p_room)>=600 then raise exception 'This drawing is full. Clear the board to start again.'; end if;
  insert into catcul.room_drawing_strokes(room_id,user_id,color,width,points) values(p_room,auth.uid(),lower(p_color),p_width,p_points) returning id into v_id;
  return v_id;
end $$;

create or replace function catcul.clear_room_drawing(p_room uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
  perform catcul.assert_active_account();
  if auth.uid() is null or not catcul.can_send_to_room(p_room) or not exists(select 1 from catcul.rooms where id=p_room and purpose <> 'community' and archived_at is null) then raise exception 'Room access required.' using errcode='42501'; end if;
  perform catcul.consume_rate('clear_room_drawing',15,60);
  perform pg_advisory_xact_lock(hashtextextended('drawing:'||p_room::text,0));
  delete from catcul.room_drawing_strokes where room_id=p_room;
end $$;
revoke all on function catcul.get_room_drawing(uuid),catcul.add_room_drawing_stroke(uuid,text,integer,jsonb),catcul.clear_room_drawing(uuid) from public,anon;
grant execute on function catcul.get_room_drawing(uuid),catcul.add_room_drawing_stroke(uuid,text,integer,jsonb),catcul.clear_room_drawing(uuid) to authenticated,service_role;

create table if not exists catcul.scheduled_texts (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references catcul.rooms(id) on delete cascade,
  sender_id uuid not null references catcul.profiles(id) on delete cascade,
  body text not null check(char_length(body) between 1 and 2000),
  send_at timestamptz not null,
  state text not null default 'pending' check(state in ('pending','sent','failed','cancelled')),
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  error text
);
create index if not exists scheduled_texts_due on catcul.scheduled_texts(send_at) where state='pending';
create index if not exists scheduled_texts_owner on catcul.scheduled_texts(sender_id,created_at desc);
alter table catcul.scheduled_texts enable row level security;
revoke all on catcul.scheduled_texts from public,anon,authenticated;
grant all on catcul.scheduled_texts to service_role;

create or replace function catcul.schedule_text(p_room uuid,p_body text,p_send_at timestamptz)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_body text:=btrim(coalesce(p_body,''));
begin
 perform catcul.assert_active_account();
 if auth.uid() is null or not catcul.can_send_to_room(p_room) or not exists(select 1 from catcul.rooms r join catcul.room_members m on m.room_id=r.id and m.user_id=auth.uid() and m.removed_at is null where r.id=p_room and r.archived_at is null and (r.posting_mode<>'admins' or m.role in ('owner','admin'))) then raise exception 'You cannot send in this room.' using errcode='42501'; end if;
 if char_length(v_body) not between 1 and 2000 or p_send_at is null or p_send_at<now()+interval '1 minute' or p_send_at>now()+interval '30 days' then raise exception 'Choose a message and a time between 1 minute and 30 days from now.'; end if;
 perform catcul.assert_body_stickers_allowed(v_body,auth.uid());
 perform catcul.consume_rate('schedule_text',40,3600);
 perform pg_advisory_xact_lock(hashtextextended('scheduled:'||auth.uid()::text,0));
 if (select count(*) from catcul.scheduled_texts where sender_id=auth.uid() and state='pending')>=30 then raise exception 'You already have 30 scheduled messages.'; end if;
 insert into catcul.scheduled_texts(room_id,sender_id,body,send_at) values(p_room,auth.uid(),v_body,p_send_at) returning id into v_id;
 return v_id;
end $$;

create or replace function catcul.my_scheduled_texts(p_room uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform catcul.assert_active_account();
 if auth.uid() is null then raise exception 'Sign in required.' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',id,'body',body,'send_at',send_at,'state',state,'error',error) order by send_at) from (select * from catcul.scheduled_texts where sender_id=auth.uid() and room_id=p_room and (state='pending' or (state='failed' and created_at>now()-interval '30 days')) order by send_at limit 50) q),'[]'::jsonb);
end $$;

create or replace function catcul.cancel_scheduled_text(p_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 perform catcul.assert_active_account();
 if auth.uid() is null then raise exception 'Sign in required.' using errcode='42501'; end if;
 update catcul.scheduled_texts set state='cancelled' where id=p_id and sender_id=auth.uid() and state in ('pending','failed');
 return found;
end $$;

create or replace function catcul.deliver_due_scheduled_texts()
returns integer language plpgsql security definer set search_path='' as $$
declare s catcul.scheduled_texts; delivered integer:=0; old_sub text:=current_setting('request.jwt.claim.sub',true); old_claims text:=current_setting('request.jwt.claims',true);
begin
 for s in select * from catcul.scheduled_texts where state='pending' and send_at<=now() order by send_at for update skip locked limit 100 loop
  begin
   perform set_config('request.jwt.claim.sub',s.sender_id::text,true);
   perform set_config('request.jwt.claims',jsonb_build_object('sub',s.sender_id,'role','authenticated')::text,true);
   if not catcul.can_send_to_room(s.room_id) then raise exception 'Room membership or account access changed.'; end if;
   insert into catcul.messages(id,room_id,sender_id,body,kind) values(s.id,s.room_id,s.sender_id,s.body,'text') on conflict(id) do nothing;
   update catcul.scheduled_texts set state='sent',delivered_at=now(),error=null where id=s.id;
   delivered:=delivered+1;
  exception when others then
   update catcul.scheduled_texts set state='failed',error='Could not send. Check room access and try again.' where id=s.id;
  end;
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(old_sub,''),true);
 perform set_config('request.jwt.claims',coalesce(old_claims,''),true);
 return delivered;
end $$;
revoke all on function catcul.schedule_text(uuid,text,timestamptz),catcul.my_scheduled_texts(uuid),catcul.cancel_scheduled_text(uuid),catcul.deliver_due_scheduled_texts() from public,anon,authenticated;
grant execute on function catcul.schedule_text(uuid,text,timestamptz),catcul.my_scheduled_texts(uuid),catcul.cancel_scheduled_text(uuid) to authenticated,service_role;
select cron.schedule('catcul-deliver-scheduled-texts','* * * * *','select catcul.deliver_due_scheduled_texts();');

-- Quiet-message webhook condition was installed using the existing trigger definition and secret; see the together_quiet_messages migration.
