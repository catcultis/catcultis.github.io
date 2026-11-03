-- Catcul shared planning / nearby / personal spaces / push.
-- Run AFTER catcul-student-upgrade.sql. No payment or money functionality.
begin;
create table if not exists catcul.room_plans(
 id uuid primary key default gen_random_uuid(),room_id uuid not null references catcul.rooms(id) on delete cascade,
 created_by uuid not null default auth.uid() references catcul.profiles(id),kind text not null check(kind in ('checklist','poll','pin','event')),
 title text not null check(char_length(title) between 1 and 120),detail text not null default '' check(char_length(detail)<=1000),
 options text[] not null default '{}',latitude double precision,longitude double precision,starts_at timestamptz,
 created_at timestamptz not null default now(),
 check((kind='poll' and cardinality(options) between 2 and 6) or (kind<>'poll' and cardinality(options)=0)),
 check((kind='pin' and latitude is not null and longitude is not null and latitude between -90 and 90 and longitude between -180 and 180) or (kind<>'pin' and latitude is null and longitude is null)),
 check(kind<>'event' or starts_at is not null)
);
create table if not exists catcul.plan_tasks(
 id uuid primary key default gen_random_uuid(),plan_id uuid not null references catcul.room_plans(id) on delete cascade,
 text text not null check(char_length(text) between 1 and 160),done boolean not null default false,
 created_by uuid not null default auth.uid() references catcul.profiles(id),created_at timestamptz not null default now()
);
create table if not exists catcul.plan_votes(
 plan_id uuid not null references catcul.room_plans(id) on delete cascade,user_id uuid not null references catcul.profiles(id),
 choice integer not null check(choice between 0 and 5),updated_at timestamptz not null default now(),primary key(plan_id,user_id)
);
create table if not exists catcul.room_sparks(room_id uuid not null references catcul.rooms(id) on delete cascade,user_id uuid not null references catcul.profiles(id),created_at timestamptz not null default now(),primary key(room_id,user_id));
create table if not exists catcul.room_moods(room_id uuid not null references catcul.rooms(id) on delete cascade,user_id uuid not null references catcul.profiles(id),mood text not null check(mood in ('studying','music','tired','happy','quiet')),expires_at timestamptz not null,primary key(room_id,user_id));
create table if not exists catcul.audio_moments(
 message_id uuid not null references catcul.messages(id) on delete cascade,user_id uuid not null references catcul.profiles(id),
 second integer not null check(second between 0 and 65),emoji text not null check(emoji in ('😂','😮','❤️')),created_at timestamptz not null default now(),primary key(message_id,user_id,second,emoji)
);
create table if not exists catcul.bedrooms(
 user_id uuid primary key references catcul.profiles(id) on delete cascade,theme text not null default 'mint' check(theme in ('mint','dusk','peach','night','sky')),
 headline text not null default '' check(char_length(headline)<=160),cards jsonb not null default '[]' check(jsonb_typeof(cards)='array' and jsonb_array_length(cards)<=6),updated_at timestamptz not null default now()
);
create table if not exists catcul.nearby_posts(
 id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references catcul.profiles(id),
 category text not null check(category in ('event','study','walk','hangout')),title text not null check(char_length(title) between 3 and 100),
 body text not null default '' check(char_length(body)<=1000),venue text not null check(char_length(venue) between 3 and 100),
 latitude double precision not null check(latitude between -90 and 90),longitude double precision not null check(longitude between -180 and 180),
 starts_at timestamptz not null,expires_at timestamptz not null,created_at timestamptz not null default now(),removed_at timestamptz,
 check(expires_at>starts_at)
);
create table if not exists catcul.nearby_reports(post_id uuid references catcul.nearby_posts(id) on delete cascade,user_id uuid references catcul.profiles(id),reason text not null check(char_length(reason) between 3 and 500),created_at timestamptz not null default now(),primary key(post_id,user_id));
create table if not exists catcul.push_subscriptions(id uuid primary key default gen_random_uuid(),user_id uuid not null references catcul.profiles(id) on delete cascade,endpoint text not null unique,p256dh text not null,auth_key text not null,created_at timestamptz not null default now());
create table if not exists catcul.room_push_preferences(room_id uuid references catcul.rooms(id) on delete cascade,user_id uuid references catcul.profiles(id),muted boolean not null default false,primary key(room_id,user_id));
create table if not exists catcul.push_deliveries(message_id uuid references catcul.messages(id) on delete cascade,subscription_id uuid references catcul.push_subscriptions(id) on delete cascade,created_at timestamptz not null default now(),primary key(message_id,subscription_id));
create index if not exists room_plans_room on catcul.room_plans(room_id,created_at desc);
create index if not exists nearby_live on catcul.nearby_posts(expires_at,latitude,longitude) where removed_at is null;

create or replace function catcul.plan_access(p_id uuid)
returns boolean language sql stable security definer set search_path='' as $$select catcul.account_is_active() and exists(select 1 from catcul.room_plans where id=p_id and catcul.can_send_to_room(room_id));$$;
revoke all on function catcul.plan_access(uuid) from public,anon;
grant execute on function catcul.plan_access(uuid) to authenticated,service_role;
do $$declare t text;begin
 foreach t in array array['room_plans','plan_tasks','plan_votes','room_sparks','room_moods','audio_moments','bedrooms','nearby_posts','nearby_reports','push_subscriptions','room_push_preferences','push_deliveries'] loop
  execute format('alter table catcul.%I enable row level security',t);
  execute format('revoke all on catcul.%I from public,anon,authenticated',t);
  execute format('grant all on catcul.%I to service_role',t);
  execute format('drop policy if exists active_account on catcul.%I',t);
  execute format('create policy active_account on catcul.%I as restrictive for all to authenticated using(catcul.account_is_active()) with check(catcul.account_is_active())',t);
  execute format('drop trigger if exists student_account_guard on catcul.%I',t);
  execute format('create trigger student_account_guard before insert or update or delete on catcul.%I for each row execute function catcul.guard_account_write()',t);
 end loop;
end $$;
grant select on catcul.room_plans,catcul.plan_tasks,catcul.plan_votes,catcul.room_sparks,catcul.room_moods,catcul.audio_moments,catcul.bedrooms,catcul.room_push_preferences to authenticated;
drop policy if exists room_plans_read on catcul.room_plans;create policy room_plans_read on catcul.room_plans for select to authenticated using(catcul.can_send_to_room(room_id));
drop policy if exists plan_tasks_read on catcul.plan_tasks;create policy plan_tasks_read on catcul.plan_tasks for select to authenticated using(catcul.plan_access(plan_id));
drop policy if exists plan_votes_read on catcul.plan_votes;create policy plan_votes_read on catcul.plan_votes for select to authenticated using(catcul.plan_access(plan_id));
drop policy if exists room_sparks_read on catcul.room_sparks;create policy room_sparks_read on catcul.room_sparks for select to authenticated using(not catcul.study_locked() and catcul.can_send_to_room(room_id));
drop policy if exists room_moods_read on catcul.room_moods;create policy room_moods_read on catcul.room_moods for select to authenticated using(not catcul.study_locked() and catcul.is_member(room_id));
drop policy if exists audio_moments_read on catcul.audio_moments;create policy audio_moments_read on catcul.audio_moments for select to authenticated using(exists(select 1 from catcul.messages m where m.id=message_id and m.deleted_at is null and catcul.is_member(m.room_id)));
drop policy if exists bedrooms_read on catcul.bedrooms;create policy bedrooms_read on catcul.bedrooms for select to authenticated using(not catcul.study_locked() and (user_id=auth.uid() or (not catcul.blocked_with(user_id) and catcul.shares_room(user_id))));
drop policy if exists room_push_owner on catcul.room_push_preferences;create policy room_push_owner on catcul.room_push_preferences for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid() and catcul.is_member(room_id));
grant insert(room_id,user_id,muted),update(room_id,user_id,muted),delete on catcul.room_push_preferences to authenticated;

create or replace function catcul.get_room_planning(p_room uuid,p_focus uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$declare ids uuid[];begin
 perform catcul.assert_active_account();if not catcul.can_send_to_room(p_room) then raise exception 'Room access required.' using errcode='42501';end if;
 select coalesce(array_agg(id),'{}'::uuid[]) into ids from(select id from catcul.room_plans where room_id=p_room order by created_at desc,id desc limit 100)p;
 if p_focus is not null and not(p_focus=any(ids)) and exists(select 1 from catcul.room_plans where id=p_focus and room_id=p_room) then ids:=array_append(ids,p_focus);end if;
 return jsonb_build_object('plans',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.id) from catcul.room_plans p where id=any(ids)),'[]'::jsonb),
 'tasks',coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from catcul.plan_tasks t where plan_id=any(ids)),'[]'::jsonb),
 'votes',coalesce((select jsonb_agg(to_jsonb(v)) from catcul.plan_votes v where plan_id=any(ids)),'[]'::jsonb));
end $$;
create or replace function catcul.create_room_plan(p_room uuid,p_kind text,p_title text,p_detail text default '',p_options text[] default '{}',p_lat double precision default null,p_lon double precision default null,p_start timestamptz default null)
returns uuid language plpgsql security definer set search_path='' as $$declare result uuid;begin
 perform catcul.assert_active_account();if not catcul.can_send_to_room(p_room) then raise exception 'Room access required.' using errcode='42501';end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 if (select count(*) from catcul.room_plans where created_by=auth.uid() and created_at>now()-interval '1 hour')>=30 then raise exception 'Please wait before adding more plans.';end if;
 if p_kind='pin' and (p_lat is null or p_lon is null or not(p_lat between -90 and 90) or not(p_lon between -180 and 180)) then raise exception 'A pin needs valid latitude and longitude.';end if;
 if p_kind='event' and (p_start is null or p_start<now()-interval '1 day' or p_start>now()+interval '1 year') then raise exception 'Choose an event time within the coming year.';end if;
 if exists(select 1 from unnest(p_options) o where o is null or char_length(btrim(o)) not between 1 and 80) then raise exception 'Poll choices must contain 1–80 characters.';end if;
 insert into catcul.room_plans(room_id,kind,title,detail,options,latitude,longitude,starts_at) values(p_room,p_kind,btrim(p_title),coalesce(p_detail,''),coalesce(p_options,'{}'),p_lat,p_lon,p_start) returning id into result;
 if p_kind in ('poll','event') then insert into catcul.messages(room_id,sender_id,body,kind) values(p_room,auth.uid(),p_title||E'\n[catcul-plan:'||result::text||']','text');end if;
 return result;
end $$;
create or replace function catcul.update_plan_task(p_plan uuid,p_task uuid default null,p_text text default null,p_done boolean default null)
returns uuid language plpgsql security definer set search_path='' as $$declare result uuid;begin
 perform catcul.assert_active_account();if not catcul.plan_access(p_plan) then raise exception 'Room access required.' using errcode='42501';end if;
 perform 1 from catcul.room_plans where id=p_plan and kind='checklist' for update;if not found then raise exception 'Checklist not found.';end if;
 if p_task is null then
  if (select count(*) from catcul.plan_tasks where plan_id=p_plan)>=100 then raise exception 'This checklist has 100 tasks.';end if;
  insert into catcul.plan_tasks(plan_id,text) values(p_plan,btrim(p_text)) returning id into result;
 else
  update catcul.plan_tasks set done=coalesce(p_done,done) where id=p_task and plan_id=p_plan returning id into result;
  if result is null then raise exception 'Task not found.';end if;
 end if;return result;
end $$;
create or replace function catcul.vote_on_plan(p_plan uuid,p_choice integer)
returns void language plpgsql security definer set search_path='' as $$declare plan catcul.room_plans;begin
 perform catcul.assert_active_account();if not catcul.plan_access(p_plan) then raise exception 'Room access required.' using errcode='42501';end if;
 select * into plan from catcul.room_plans where id=p_plan;
 if p_choice is null or p_choice<0 or (plan.kind='poll' and p_choice>=cardinality(plan.options)) or (plan.kind='event' and p_choice>2) or plan.kind not in ('poll','event') then raise exception 'Invalid vote.';end if;
 insert into catcul.plan_votes(plan_id,user_id,choice) values(p_plan,auth.uid(),p_choice) on conflict(plan_id,user_id) do update set choice=excluded.choice,updated_at=now();
end $$;
create or replace function catcul.delete_room_plan(p_plan uuid)
returns void language plpgsql security definer set search_path='' as $$begin
 perform catcul.assert_active_account();if not exists(select 1 from catcul.room_plans p where p.id=p_plan and catcul.is_member(p.room_id) and (p.created_by=auth.uid() or exists(select 1 from catcul.room_members m where m.room_id=p.room_id and m.user_id=auth.uid() and m.role='owner' and m.removed_at is null))) then raise exception 'Only the creator or room owner can delete this plan.' using errcode='42501';end if;
 delete from catcul.room_plans where id=p_plan;
end $$;
create or replace function catcul.send_spark(p_room uuid)
returns void language plpgsql security definer set search_path='' as $$begin
 perform catcul.assert_active_account();if catcul.study_locked() or not catcul.can_send_to_room(p_room) then raise exception 'Unlock Study Mode and open an accessible chat first.' using errcode='42501';end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 if exists(select 1 from catcul.room_sparks where room_id=p_room and user_id=auth.uid() and created_at>now()-interval '1 minute') then raise exception 'Give your Spark a minute before sending another.';end if;
 insert into catcul.room_sparks(room_id,user_id) values(p_room,auth.uid()) on conflict(room_id,user_id) do update set created_at=now();
end $$;
create or replace function catcul.set_room_mood(p_room uuid,p_mood text)
returns void language plpgsql security definer set search_path='' as $$begin
 perform catcul.assert_active_account();if catcul.study_locked() or not catcul.is_member(p_room) then raise exception 'Unlock Study Mode and open your room first.' using errcode='42501';end if;
 if p_mood='' then delete from catcul.room_moods where room_id=p_room and user_id=auth.uid();return;end if;
 insert into catcul.room_moods(room_id,user_id,mood,expires_at) values(p_room,auth.uid(),p_mood,now()+interval '8 hours') on conflict(room_id,user_id) do update set mood=excluded.mood,expires_at=excluded.expires_at;
end $$;
create or replace function catcul.audio_reaction_summary(p_messages uuid[])
returns jsonb language plpgsql stable security invoker set search_path='' as $$begin
 perform catcul.assert_active_account();if coalesce(cardinality(p_messages),0)>200 then raise exception 'Too many voice notes in one request.';end if;
 return coalesce((select jsonb_agg(to_jsonb(s)) from(select message_id,second,emoji,count(*) as count from catcul.audio_moments where message_id=any(p_messages) group by message_id,second,emoji)s),'[]'::jsonb);
end $$;
create or replace function catcul.react_to_audio(p_message uuid,p_second integer,p_emoji text)
returns void language plpgsql security definer set search_path='' as $$begin
 perform catcul.assert_active_account();if not exists(select 1 from catcul.messages where id=p_message and kind='audio' and deleted_at is null and catcul.can_send_to_room(room_id)) then raise exception 'Voice note unavailable.' using errcode='42501';end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 if (select count(*) from catcul.audio_moments where message_id=p_message and user_id=auth.uid())>=30 then raise exception 'You can pin up to 30 reactions to each voice note.';end if;
 insert into catcul.audio_moments(message_id,user_id,second,emoji) values(p_message,auth.uid(),p_second,p_emoji) on conflict do nothing;
end $$;
create or replace function catcul.save_bedroom(p_theme text,p_headline text,p_cards jsonb)
returns void language plpgsql security definer set search_path='' as $$declare card jsonb;begin
 perform catcul.assert_active_account();if auth.uid() is null or catcul.study_locked() then raise exception 'Unlock Study Mode first.' using errcode='42501';end if;
 if jsonb_typeof(p_cards)<>'array' or jsonb_array_length(p_cards)>6 then raise exception 'Use up to six cards.';end if;
 for card in select value from jsonb_array_elements(p_cards) loop
  if jsonb_typeof(card)<>'object' or coalesce(card->>'kind','') not in ('listening','watching','playing','thinking') or char_length(coalesce(card->>'text','')) not between 1 and 300 or char_length(coalesce(card->>'url',''))>2048 or (coalesce(card->>'url','')<>'' and (card->>'url')!~ '^https://[^\s]+$') then raise exception 'Use valid status cards and optional HTTPS links.';end if;
 end loop;
 insert into catcul.bedrooms(user_id,theme,headline,cards) values(auth.uid(),p_theme,p_headline,p_cards) on conflict(user_id) do update set theme=excluded.theme,headline=excluded.headline,cards=excluded.cards,updated_at=now();
end $$;
create or replace function catcul.publish_nearby(p_category text,p_title text,p_body text,p_venue text,p_lat double precision,p_lon double precision,p_start timestamptz,p_end timestamptz)
returns uuid language plpgsql security definer set search_path='' as $$declare result uuid;begin
 perform catcul.assert_active_account();if auth.uid() is null or catcul.study_locked() then raise exception 'Unlock Study Mode first.' using errcode='42501';end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 if (select count(*) from catcul.nearby_posts where user_id=auth.uid() and created_at>now()-interval '1 day')>=10 then raise exception 'Up to 10 nearby posts per day.';end if;
 if p_start is null or p_end is null or p_end<=now() or p_end>now()+interval '24 hours' or p_start<p_end-interval '24 hours' then raise exception 'Nearby posts must end within the next 24 hours.';end if;
 insert into catcul.nearby_posts(user_id,category,title,body,venue,latitude,longitude,starts_at,expires_at) values(auth.uid(),p_category,btrim(p_title),coalesce(p_body,''),btrim(p_venue),p_lat,p_lon,p_start,p_end) returning id into result;return result;
end $$;
create or replace function catcul.distance_meters(a double precision,b double precision,c double precision,d double precision)
returns double precision language sql immutable set search_path='' as $$
 select 6371000.0*acos(least(1.0,greatest(-1.0,sin(radians(a))*sin(radians(c))+cos(radians(a))*cos(radians(c))*cos(radians(d-b)))));
$$;
create or replace function catcul.discover_nearby(p_lat double precision,p_lon double precision)
returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform catcul.assert_active_account();if auth.uid() is null or catcul.study_locked() then raise exception 'Unlock Study Mode first.' using errcode='42501';end if;
 if p_lat is null or p_lon is null or not(p_lat between -90 and 90) or not(p_lon between -180 and 180) then raise exception 'Choose a valid search location.';end if;
 -- Search coordinates are never written to a table. Posts advertise venues.
 return coalesce((select jsonb_agg(to_jsonb(q)) from (
 select n.*,p.username,p.display_name,round(catcul.distance_meters(p_lat,p_lon,n.latitude,n.longitude))::integer as distance_m
 from catcul.nearby_posts n join catcul.profiles p on p.id=n.user_id
 where n.removed_at is null and n.expires_at>now() and not catcul.blocked_with(n.user_id)
 and not exists(select 1 from catcul.account_controls c where c.user_id=n.user_id and c.suspended)
 and catcul.distance_meters(p_lat,p_lon,n.latitude,n.longitude)<=500
 order by distance_m,n.created_at desc limit 50
 )q),'[]'::jsonb);
end $$;
create or replace function catcul.report_nearby(p_post uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$begin
 perform catcul.assert_active_account();if auth.uid() is null or catcul.study_locked() or not exists(select 1 from catcul.nearby_posts where id=p_post and removed_at is null and expires_at>now()) then raise exception 'Post unavailable.' using errcode='42501';end if;
 perform 1 from catcul.profiles where id=auth.uid() for update;
 if exists(select 1 from catcul.nearby_reports where post_id=p_post and user_id=auth.uid()) then return;end if;
 if (select count(*) from catcul.nearby_reports where user_id=auth.uid() and created_at>now()-interval '1 day')>=20 then raise exception 'Daily nearby report limit reached.';end if;
 insert into catcul.nearby_reports(post_id,user_id,reason) values(p_post,auth.uid(),p_reason) on conflict do nothing;
end $$;
create or replace function catcul.remove_nearby(p_post uuid,p_reason text default 'Removed by author')
returns void language plpgsql security definer set search_path='' as $$begin
 perform catcul.assert_active_account();if not catcul.is_platform_admin() and not exists(select 1 from catcul.nearby_posts where id=p_post and user_id=auth.uid()) then raise exception 'Only the author or administrator can remove this post.' using errcode='42501';end if;
 update catcul.nearby_posts set removed_at=now() where id=p_post;
 if catcul.is_platform_admin() then insert into catcul.admin_audit(actor_id,action,target_id,detail) values(auth.uid(),'remove_nearby_post',p_post,jsonb_build_object('note',left(p_reason,500)));end if;
end $$;
create or replace function catcul.admin_nearby()
returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 perform catcul.require_platform_admin();return coalesce((select jsonb_agg(to_jsonb(q)) from(select n.*,p.username,(select count(*) from catcul.nearby_reports r where r.post_id=n.id) as reports,(select coalesce(jsonb_agg(to_jsonb(z)),'[]'::jsonb) from(select reason,created_at from catcul.nearby_reports where post_id=n.id order by created_at desc limit 20)z) as report_details from catcul.nearby_posts n join catcul.profiles p on p.id=n.user_id where n.removed_at is null order by reports desc,n.created_at desc limit 100)q),'[]'::jsonb);
end $$;
create or replace function catcul.room_memories(p_room uuid,p_period text default 'week')
returns setof catcul.messages language plpgsql stable security invoker set search_path='' as $$begin
 perform catcul.assert_active_account();if catcul.study_locked() or not catcul.is_member(p_room) then raise exception 'Unlock Study Mode and open your room first.' using errcode='42501';end if;
 return query select m.* from catcul.messages m where m.room_id=p_room and m.deleted_at is null and (m.kind in ('photo','audio') or (char_length(m.body)<=280 and m.body not like '%[catcul-plan:%')) and case when p_period='year' then m.created_at::date=(current_date-interval '1 year')::date else m.created_at>now()-interval '7 days' end order by m.created_at desc limit 12;
end $$;
create or replace function catcul.topic_allowed(p_topic text)
returns boolean language plpgsql stable security definer set search_path='' as $$begin
 if not catcul.account_is_active() then return false;end if; -- CATCUL_ACTIVE_GUARD
 if p_topic in ('catcul:user:'||auth.uid()::text,'catcul:school:'||auth.uid()::text,'catcul:diary:'||auth.uid()::text) then return true;end if;
 if p_topic !~ '^catcul:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(:extras)?$' then return false;end if;
 return catcul.can_send_to_room(split_part(p_topic,':',2)::uuid);
end $$;
-- Explicit API allowlist. Service-only tables never become browser-readable.
do $$declare f record;begin
 for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='catcul' and p.proname in ('get_room_planning','create_room_plan','update_plan_task','vote_on_plan','delete_room_plan','send_spark','set_room_mood','react_to_audio','audio_reaction_summary','save_bedroom','publish_nearby','discover_nearby','report_nearby','remove_nearby','admin_nearby','room_memories') loop
 execute format('revoke all on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated,service_role',f.signature);
 end loop;
end $$;
do $$declare t text;begin
 foreach t in array array['room_plans','plan_tasks','plan_votes','room_sparks','room_moods','audio_moments'] loop
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='catcul' and tablename=t) then execute format('alter publication supabase_realtime add table catcul.%I',t);end if;
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
