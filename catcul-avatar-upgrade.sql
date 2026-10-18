-- CATCUL / 003 — Original customizable cat characters
-- Run after catcul-setup.sql and catcul-social-upgrade.sql. Existing data is kept.
begin;
alter table catcul.profiles add column if not exists avatar jsonb not null default '{}'::jsonb;
create or replace function catcul.valid_avatar(p_value jsonb)
returns boolean language plpgsql immutable set search_path='' as $$
declare item record; allowed jsonb:= '{"shape":["squircle","puff","bean"],"pattern":["plain","tabby","tuxedo","patches"],"eyes":["bright","sleepy","wink","sparkle"],"mouth":["smile","tiny","blep","grin"],"cheeks":["rosy","freckles","none"],"ears":["pointed","round","folded","none"],"tail":["curled","fluffy","long","none"],"outfit":["none","hoodie","overalls","scarf"],"accessory":["none","glasses","bow","headphones","crown"],"whiskers":["yes","no"]}'::jsonb;
begin
 if p_value is null or jsonb_typeof(p_value)<>'object' or octet_length(p_value::text)>2048 then return false;end if;
 for item in select key,value from jsonb_each(p_value) loop
  if item.key='v' then
   if item.value<>'1'::jsonb then return false;end if;
  elsif item.key in ('fur','accent','background') then
   if jsonb_typeof(item.value)<>'string' or (item.value#>>'{}') !~ '^#[0-9a-fA-F]{6}$' then return false;end if;
  elsif allowed ? item.key then
   if jsonb_typeof(item.value)<>'string' or not ((allowed->item.key) ? (item.value#>>'{}')) then return false;end if;
  else return false;
  end if;
 end loop;return true;
end $$;
do $$begin
 if not exists(select 1 from pg_constraint where conname='catcul_avatar_safe' and conrelid='catcul.profiles'::regclass) then
  alter table catcul.profiles add constraint catcul_avatar_safe check(catcul.valid_avatar(avatar));
 end if;
end $$;
grant update(avatar) on catcul.profiles to authenticated;
revoke all on function catcul.valid_avatar(jsonb) from public,anon;
grant execute on function catcul.valid_avatar(jsonb) to authenticated,service_role;

-- Retain the existing search API for older clients; the new one adds safe avatar data.
create or replace function catcul.find_people_with_avatars(p_query text)
returns table(id uuid,username text,display_name text,color text,avatar jsonb)
language sql stable security definer set search_path='' as $$
 select f.id,f.username,f.display_name,f.color,p.avatar from catcul.find_people(p_query) f join catcul.profiles p on p.id=f.id;
$$;
revoke all on function catcul.find_people_with_avatars(text) from public,anon;
grant execute on function catcul.find_people_with_avatars(text) to authenticated,service_role;

create or replace function catcul.social_state()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare u uuid:=auth.uid(); result jsonb;
begin
 if u is null then raise exception 'Sign in first.' using errcode='42501'; end if;
 select jsonb_build_object(
 'friends',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'avatar',p.avatar,'best',coalesce(b.is_favorite,false)) order by coalesce(b.is_favorite,false) desc,p.display_name) from catcul.friendships f join catcul.profiles p on p.id=case when f.user_low=u then f.user_high else f.user_low end left join catcul.best_friends b on b.owner_id=u and b.friend_id=p.id where u in(f.user_low,f.user_high) and f.status='accepted' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'incoming',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'avatar',p.avatar)) from catcul.friendships f join catcul.profiles p on p.id=f.requested_by where u in(f.user_low,f.user_high) and f.requested_by<>u and f.status='pending' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'outgoing',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'avatar',p.avatar)) from catcul.friendships f join catcul.profiles p on p.id=case when f.user_low=u then f.user_high else f.user_low end where u in(f.user_low,f.user_high) and f.requested_by=u and f.status='pending' and not catcul.blocked_with(p.id)),'[]'::jsonb),
 'blocked',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'display_name',p.display_name,'color',p.color,'avatar',p.avatar)) from catcul.user_blocks b join catcul.profiles p on p.id=b.blocked_id where b.blocker_id=u and b.active),'[]'::jsonb)
 ) into result;return result;
end $$;

create or replace function catcul.my_voice_calls()
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in first.' using errcode='42501'; end if;
 perform catcul.expire_voice_calls();
 select coalesce(jsonb_agg(to_jsonb(x) order by x.started_at desc),'[]'::jsonb) into result from (
 select c.*,r.kind,r.name as room_name,coalesce(p.state,'available') as my_state,sp.display_name as caller_name,sp.color as caller_color,sp.avatar as caller_avatar,
 case when r.kind='direct' then peer.display_name else r.name end as title
 from catcul.voice_calls c left join catcul.call_participants p on p.call_id=c.id and p.user_id=auth.uid() join catcul.rooms r on r.id=c.room_id join catcul.profiles sp on sp.id=c.started_by
 left join catcul.profiles peer on peer.id=case when r.direct_low=auth.uid() then r.direct_high when r.direct_high=auth.uid() then r.direct_low else null end
 where (p.user_id=auth.uid() or (r.kind='group' and c.ended_at is null)) and catcul.is_member(c.room_id) and c.started_at>now()-interval '7 days' order by c.started_at desc limit 40) x;return result;
end $$;

create or replace function catcul.authorize_voice_join(p_call_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c catcul.voice_calls; p catcul.profiles;
begin
 select * into c from catcul.voice_calls where id=p_call_id;
 if not found or c.ended_at is not null or (c.status='ringing' and c.started_at<now()-interval '75 seconds') or not catcul.can_send_to_room(c.room_id) then raise exception 'Call access denied.' using errcode='42501'; end if;
 if not exists(select 1 from catcul.call_participants where call_id=c.id and user_id=auth.uid() and state='accepted') then raise exception 'Accept the call before joining.' using errcode='42501'; end if;
 select * into p from catcul.profiles where id=auth.uid();
 return jsonb_build_object('call_id',c.id,'room_id',c.room_id,'media_room','catcul_'||replace(c.id::text,'-',''),'identity',p.id,'name',p.display_name,'color',p.color,'avatar',p.avatar);
end $$;
notify pgrst,'reload schema';
commit;
select 'Catcul character profiles are ready. Publish the updated chat page.' as next_step;
