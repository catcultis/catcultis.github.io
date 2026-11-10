-- =====================================================================
-- Catcul Monetization & Cumulative Tiers Upgrade (Idempotent)
-- Run in Supabase SQL Editor AFTER catcul-chat-tools-upgrade.sql.
--
-- Tiers (cumulative):
--   free      (rank 0) : Core chats, voice calls, voice notes, files,
--                        starter app themes & starter stickers, Notes,
--                        Diary, viewing Stories & Spotlight.
--   plus      (rank 1) : Catcul+       -> + LiveKit video calls + Plus themes & stickers
--   plusplus  (rank 2) : Catcul++      -> + Cat Filter Snap Camera + Studio themes & stickers
--   premium   (rank 3) : Catcul Premium -> + Stories (24h), Spotlight, Video posting,
--                        Signature app themes & full sticker vault.
--
-- Platform administrators (catcul.platform_admins) automatically receive
-- Catcul Premium ('premium', rank 3) enforced server-side.
-- =====================================================================

begin;

do $$
begin
  if to_regclass('catcul.room_chat_preferences') is null then
    raise exception 'Please run catcul-chat-tools-upgrade.sql first, then run catcul-monetization-upgrade.sql.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Tier Rank Helpers & Billing Tables
-- ---------------------------------------------------------------------
create or replace function catcul.tier_rank(p_tier text)
returns smallint language sql immutable set search_path = '' as $$
  select case coalesce(p_tier, 'free')
    when 'premium'  then 3::smallint
    when 'plusplus' then 2::smallint
    when 'plus'     then 1::smallint
    else 0::smallint
  end;
$$;

create table if not exists catcul.billing_config (
  id smallint primary key default 1 check (id = 1),
  environment text not null default 'sandbox' check (environment in ('sandbox','production')),
  client_token text not null default '' check (char_length(client_token) <= 200),
  currency text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  deepar_license_key text not null default '' check (char_length(deepar_license_key) <= 320),
  updated_at timestamptz not null default now(),
  updated_by uuid references catcul.profiles(id)
);

alter table catcul.billing_config
  add column if not exists deepar_license_key text not null default '';
do $$
begin
  if not exists (
    select 1 from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'catcul' and t.relname = 'billing_config' and c.conname = 'billing_config_deepar_len_check'
  ) then
    alter table catcul.billing_config
      add constraint billing_config_deepar_len_check check (char_length(deepar_license_key) <= 320);
  end if;
end $$;

insert into catcul.billing_config (id, environment, client_token, currency)
values (1, 'sandbox', '', 'USD')
on conflict (id) do nothing;

create table if not exists catcul.billing_plans (
  tier text primary key check (tier in ('plus','plusplus','premium')),
  name text not null check (char_length(name) between 2 and 40),
  tagline text not null default '' check (char_length(tagline) <= 180),
  monthly_price_display text not null check (char_length(monthly_price_display) between 1 and 24),
  yearly_price_display text not null check (char_length(yearly_price_display) between 1 and 24),
  monthly_price_id text not null default '' check (monthly_price_id = '' or monthly_price_id ~ '^pri_[a-z0-9]{18,40}$'),
  yearly_price_id text not null default '' check (yearly_price_id = '' or yearly_price_id ~ '^pri_[a-z0-9]{18,40}$'),
  active boolean not null default true,
  updated_at timestamptz not null default now()
);

insert into catcul.billing_plans (tier, name, tagline, monthly_price_display, yearly_price_display)
values
  ('plus',     'Catcul+',        'Live 1:1 & group video calls plus Catcul+ themes & stickers.',                    '$3.99',  '$39'),
  ('plusplus', 'Catcul++',       'Cat Filter Snap Camera, video calls, and Studio themes & stickers.',              '$6.99',  '$69'),
  ('premium',  'Catcul Premium', 'Everything unlocked: 24h Stories, Spotlight, video posting & Signature themes.',  '$11.99', '$119')
on conflict (tier) do nothing;

create table if not exists catcul.user_subscriptions (
  user_id uuid primary key references catcul.profiles(id) on delete cascade,
  tier text not null check (tier in ('plus','plusplus','premium')),
  status text not null check (status in ('active','trialing','past_due','paused','canceled')),
  billing_interval text check (billing_interval is null or billing_interval in ('month','year')),
  paddle_customer_id text check (paddle_customer_id is null or char_length(paddle_customer_id) <= 80),
  paddle_subscription_id text unique check (paddle_subscription_id is null or char_length(paddle_subscription_id) <= 80),
  paddle_price_id text check (paddle_price_id is null or char_length(paddle_price_id) <= 80),
  paddle_transaction_id text check (paddle_transaction_id is null or char_length(paddle_transaction_id) <= 80),
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  last_event_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists user_subscriptions_customer_idx on catcul.user_subscriptions(paddle_customer_id) where paddle_customer_id is not null;

create table if not exists catcul.tier_grants (
  user_id uuid primary key references catcul.profiles(id) on delete cascade,
  tier text not null check (tier in ('plus','plusplus','premium')),
  note text not null default '' check (char_length(note) <= 240),
  expires_at timestamptz,
  granted_by uuid references catcul.profiles(id),
  updated_at timestamptz not null default now()
);

create table if not exists catcul.billing_webhook_events (
  event_id text primary key check (char_length(event_id) between 4 and 120),
  event_type text not null check (char_length(event_type) <= 80),
  occurred_at timestamptz,
  processed_at timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['billing_config','billing_plans','user_subscriptions','tier_grants','billing_webhook_events'] loop
    execute format('alter table catcul.%I enable row level security', t);
    execute format('revoke all on catcul.%I from public, anon, authenticated', t);
    execute format('grant all on catcul.%I to service_role', t);
  end loop;
end $$;

grant select on catcul.billing_plans to anon, authenticated;
drop policy if exists billing_plans_read on catcul.billing_plans;
create policy billing_plans_read on catcul.billing_plans for select to anon, authenticated using (active);

grant select on catcul.user_subscriptions to authenticated;
drop policy if exists user_subscriptions_own_read on catcul.user_subscriptions;
create policy user_subscriptions_own_read on catcul.user_subscriptions for select to authenticated
  using (catcul.account_is_active() and user_id = (select auth.uid()));

grant select on catcul.tier_grants to authenticated;
drop policy if exists tier_grants_own_read on catcul.tier_grants;
create policy tier_grants_own_read on catcul.tier_grants for select to authenticated
  using (catcul.account_is_active() and user_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- 2. Server-Authoritative Effective Tier (Platform Admin => Premium)
-- ---------------------------------------------------------------------
create or replace function catcul.effective_tier(p_user uuid default auth.uid())
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_sub_tier text := 'free';
  v_grant_tier text := 'free';
begin
  if p_user is null then
    return 'free';
  end if;
  if exists (select 1 from catcul.account_controls where user_id = p_user and suspended) then
    return 'free';
  end if;
  -- Platform owners/administrators automatically get Catcul Premium (everything unlocked).
  if exists (select 1 from catcul.platform_admins where user_id = p_user) then
    return 'premium';
  end if;

  select s.tier into v_sub_tier
  from catcul.user_subscriptions s
  where s.user_id = p_user
    and (
      s.status in ('active','trialing','past_due')
      or (s.status = 'canceled' and s.current_period_end is not null and s.current_period_end > now())
    );
  v_sub_tier := coalesce(v_sub_tier, 'free');

  select g.tier into v_grant_tier
  from catcul.tier_grants g
  where g.user_id = p_user
    and (g.expires_at is null or g.expires_at > now());
  v_grant_tier := coalesce(v_grant_tier, 'free');

  if catcul.tier_rank(v_grant_tier) > catcul.tier_rank(v_sub_tier) then
    return v_grant_tier;
  end if;
  return v_sub_tier;
end $$;

create or replace function catcul.has_tier(p_min_tier text, p_user uuid default auth.uid())
returns boolean language sql stable security definer set search_path = '' as $$
  select catcul.tier_rank(catcul.effective_tier(p_user)) >= catcul.tier_rank(p_min_tier);
$$;

-- ---------------------------------------------------------------------
-- 3. App Themes & Sticker Exclusivity (All Tiers, Scaling Exclusivity)
-- ---------------------------------------------------------------------
create or replace function catcul.theme_min_tier(p_theme text)
returns text language sql immutable set search_path = '' as $$
  select case coalesce(p_theme, '')
    when 'meadow'        then 'free'
    when 'midnight'      then 'free'
    when 'matcha-cloud'  then 'plus'
    when 'ocean-glass'   then 'plus'
    when 'sakura-bloom'  then 'plusplus'
    when 'sunset-sorbet' then 'plusplus'
    when 'cyber-lime'    then 'plusplus'
    when 'emerald-royal' then 'premium'
    when 'aurora-velvet' then 'premium'
    when 'obsidian-gold' then 'premium'
    else 'invalid'
  end;
$$;

create or replace function catcul.sticker_min_tier(p_sticker text)
returns text language sql immutable set search_path = '' as $$
  select case coalesce(p_sticker, '')
    when 'wave-kitty'     then 'free'
    when 'cozy-nap'       then 'free'
    when 'thumbs-paws'    then 'free'
    when 'study-paws'     then 'free'
    when 'coffee-boost'   then 'plus'
    when 'boba-sip'       then 'plus'
    when 'video-wave'     then 'plus'
    when 'heart-paws'     then 'plus'
    when 'laser-shades'   then 'plusplus'
    when 'snap-flash'     then 'plusplus'
    when 'sakura-purr'    then 'plusplus'
    when 'party-whiskers' then 'plusplus'
    when 'crown-cat'      then 'premium'
    when 'vip-trophy'     then 'premium'
    when 'starlight-orbit'then 'premium'
    when 'diamond-vibes'  then 'premium'
    else 'invalid'
  end;
$$;

alter table catcul.profiles add column if not exists app_theme text not null default 'meadow';
do $$
declare r record;
begin
  for r in select c.conname from pg_constraint c join pg_class t on t.oid = c.conrelid join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'catcul' and t.relname = 'profiles' and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%app_theme%' loop
    execute format('alter table catcul.profiles drop constraint %I', r.conname);
  end loop;
end $$;
alter table catcul.profiles add constraint profiles_app_theme_check
  check (catcul.theme_min_tier(app_theme) <> 'invalid');

create or replace function catcul.effective_app_theme(p_user uuid default auth.uid())
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_theme text;
  v_req text;
begin
  if p_user is null then return 'meadow'; end if;
  select app_theme into v_theme from catcul.profiles where id = p_user;
  v_theme := coalesce(v_theme, 'meadow');
  v_req := catcul.theme_min_tier(v_theme);
  if v_req = 'invalid' or not catcul.has_tier(v_req, p_user) then
    return 'meadow';
  end if;
  return v_theme;
end $$;

create or replace function catcul.set_app_theme(p_theme text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_req text;
begin
  perform catcul.assert_active_account();
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  perform catcul.consume_rate('set_app_theme', 60, 3600);
  v_req := catcul.theme_min_tier(p_theme);
  if v_req = 'invalid' then
    raise exception 'Unknown Catcul app theme.';
  end if;
  if not catcul.has_tier(v_req, auth.uid()) then
    raise exception 'This theme requires %.',
      case v_req when 'plus' then 'Catcul+' when 'plusplus' then 'Catcul++' else 'Catcul Premium' end
      using errcode = '42501';
  end if;
  update catcul.profiles set app_theme = p_theme where id = auth.uid();
  return p_theme;
end $$;

-- Extend per-room wallpaper choices with Generated Anime & Wallhaven 4K anime wallpapers + sticker wallpapers.
create or replace function catcul.wallpaper_min_tier(p_wallpaper text)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_wallpaper is null or p_wallpaper = '' then 'free'
    when p_wallpaper in (
      'plain','mint','sand','rose','sky','night','paw-doodles',
      'anime-ghibli-meadow','anime-shinkai-sky',
      'wh:yx5kml','wh:8oy372','wh:mlzoy1'
    ) then 'free'
    when p_wallpaper in (
      'matcha-stickers',
      'anime-emerald-sanctuary','anime-cursed-shrine',
      'wh:pkxwwe','wh:ymwj9d','wh:m99dom','wh:0qd8dn','wh:xl635v'
    ) then 'plus'
    when p_wallpaper in (
      'sakura-stickers','cyber-stickers',
      'anime-sakura-train','anime-samurai-moon','anime-graffiti-knight',
      'wh:1kdglv','wh:96pzzd','wh:571998','wh:o3km89','wh:gpjyvl','wh:m3p2l8','wh:9mjoy1','wh:q21ezq','wh:g7leed','wh:ymvrjl'
    ) then 'plusplus'
    when p_wallpaper in (
      'royal-stickers','starlight-stickers',
      'anime-neon-shibuya','anime-shadow-monarch','anime-golden-eclipse',
      'wh:72lej9','wh:v973e3','wh:yjr3lk','wh:yx7g8k','wh:gjyoq7','wh:x1xy9l','wh:42v990','wh:g7jgk3','wh:j323py'
    ) then 'premium'
    when p_wallpaper ~ '^wallhaven:[a-z0-9]{4,12}\.(jpg|png)$' then 'premium'
    when p_wallpaper ~ '^wh:[a-z0-9]{4,12}$' then 'premium'
    else 'invalid'
  end;
$$;

do $$
declare r record;
begin
  for r in select c.conname from pg_constraint c join pg_class t on t.oid = c.conrelid join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'catcul' and t.relname = 'room_chat_preferences' and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%wallpaper%' loop
    execute format('alter table catcul.room_chat_preferences drop constraint %I', r.conname);
  end loop;
end $$;
alter table catcul.room_chat_preferences add constraint room_chat_preferences_wallpaper_check
  check (catcul.wallpaper_min_tier(wallpaper) <> 'invalid');

drop policy if exists chat_prefs_insert on catcul.room_chat_preferences;
create policy chat_prefs_insert on catcul.room_chat_preferences for insert to authenticated
  with check (user_id = (select auth.uid()) and catcul.is_member(room_id) and catcul.has_tier(catcul.wallpaper_min_tier(wallpaper), (select auth.uid())));

drop policy if exists chat_prefs_update on catcul.room_chat_preferences;
create policy chat_prefs_update on catcul.room_chat_preferences for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and catcul.has_tier(catcul.wallpaper_min_tier(wallpaper), (select auth.uid())));

create or replace function catcul.set_room_personalization(p_room_id uuid, p_wallpaper text, p_label text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_req text;
begin
  perform catcul.assert_active_account();
  perform catcul.consume_rate('room_personal', 40, 3600);
  if not catcul.is_member(p_room_id) then raise exception 'Room membership required.' using errcode = '42501'; end if;
  v_req := catcul.wallpaper_min_tier(p_wallpaper);
  if v_req = 'invalid' then
    raise exception 'Unknown wallpaper.';
  end if;
  if not catcul.has_tier(v_req, auth.uid()) then
    raise exception 'This sticker wallpaper requires %.',
      case v_req when 'plus' then 'Catcul+' when 'plusplus' then 'Catcul++' else 'Catcul Premium' end
      using errcode = '42501';
  end if;
  insert into catcul.room_chat_preferences(room_id, user_id, wallpaper, custom_label, updated_at)
  values (p_room_id, auth.uid(), p_wallpaper, nullif(left(btrim(coalesce(p_label, '')), 80), ''), now())
  on conflict (room_id, user_id) do update set
    wallpaper = excluded.wallpaper,
    custom_label = excluded.custom_label,
    updated_at = now();
end $$;

-- ---------------------------------------------------------------------
-- 4. Public Pricing, Entitlements & Public Tier Badges RPCs
-- ---------------------------------------------------------------------
create or replace function catcul.get_public_pricing()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'environment', coalesce((select environment from catcul.billing_config where id = 1), 'sandbox'),
    'currency', coalesce((select currency from catcul.billing_config where id = 1), 'USD'),
    'client_token', coalesce((select client_token from catcul.billing_config where id = 1), ''),
    'checkout_ready', exists(
      select 1 from catcul.billing_config c
      where c.id = 1 and btrim(c.client_token) <> ''
    ) and exists(
      select 1 from catcul.billing_plans p
      where p.active and (p.monthly_price_id <> '' or p.yearly_price_id <> '')
    ),
    'plans', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tier', p.tier,
        'rank', catcul.tier_rank(p.tier),
        'name', p.name,
        'tagline', p.tagline,
        'monthly_price_display', p.monthly_price_display,
        'yearly_price_display', p.yearly_price_display,
        'monthly_price_id', p.monthly_price_id,
        'yearly_price_id', p.yearly_price_id,
        'monthly_ready', p.monthly_price_id <> '',
        'yearly_ready', p.yearly_price_id <> ''
      ) order by catcul.tier_rank(p.tier))
      from catcul.billing_plans p
      where p.active
    ), '[]'::jsonb)
  );
$$;

create or replace function catcul.get_my_entitlements()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_admin boolean := catcul.is_platform_admin();
  v_tier text;
  v_rank smallint;
  v_sub catcul.user_subscriptions;
  v_grant catcul.tier_grants;
  v_source text := 'free';
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  v_tier := catcul.effective_tier(v_uid);
  v_rank := catcul.tier_rank(v_tier);
  select * into v_sub from catcul.user_subscriptions where user_id = v_uid;
  select * into v_grant from catcul.tier_grants where user_id = v_uid and (expires_at is null or expires_at > now());

  if v_admin then
    v_source := 'admin';
  elsif v_grant.user_id is not null and catcul.tier_rank(v_grant.tier) >= v_rank and v_rank > 0 then
    v_source := 'grant';
  elsif v_sub.user_id is not null and v_rank > 0 then
    v_source := 'paddle';
  end if;

  return jsonb_build_object(
    'tier', v_tier,
    'rank', v_rank,
    'source', v_source,
    'is_admin', v_admin,
    'app_theme', catcul.effective_app_theme(v_uid),
    'status', coalesce(case when v_admin then 'active' else v_sub.status end, case when v_rank > 0 then 'active' else 'free' end),
    'billing_interval', v_sub.billing_interval,
    'current_period_end', coalesce(v_sub.current_period_end, v_grant.expires_at),
    'cancel_at_period_end', coalesce(v_sub.cancel_at_period_end, false),
    'has_portal', v_sub.paddle_customer_id is not null and v_sub.paddle_customer_id <> '',
    'features', jsonb_build_object(
      'video_calls', v_rank >= 1,
      'cat_snap_filters', v_rank >= 2,
      'stories_post', v_rank >= 3,
      'spotlight_post', v_rank >= 3,
      'video_posts', v_rank >= 3
    )
  );
end $$;

create or replace function catcul.public_user_tiers(p_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform catcul.assert_active_account();
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_object_agg(u.id::text, jsonb_build_object(
      'tier', catcul.effective_tier(u.id),
      'is_admin', exists(select 1 from catcul.platform_admins a where a.user_id = u.id)
    ))
    from (
      select distinct unnest(coalesce(p_ids[1:120], '{}'::uuid[])) as id
    ) u
    join catcul.profiles p on p.id = u.id
  ), '{}'::jsonb);
end $$;

-- Also enrich get_app_access() so initial boot already knows effective_tier!
create or replace function catcul.get_app_access()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'active', catcul.account_is_active(),
    'is_admin', catcul.is_platform_admin(),
    'role', (select role from catcul.platform_admins where user_id = auth.uid()),
    'reason', (select reason from catcul.account_controls where user_id = auth.uid() and suspended),
    'tier', catcul.effective_tier(auth.uid()),
    'tier_rank', catcul.tier_rank(catcul.effective_tier(auth.uid())),
    'app_theme', catcul.effective_app_theme(auth.uid())
  );
$$;

-- ---------------------------------------------------------------------
-- 5. Catcul+ Video Calling Authorization (LiveKit CAMERA Grant)
-- ---------------------------------------------------------------------
alter table catcul.voice_calls add column if not exists video_mode boolean not null default false;

create or replace function catcul.enable_call_video(p_call_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  c catcul.voice_calls;
begin
  perform catcul.assert_active_account();
  if not catcul.has_tier('plus', auth.uid()) then
    raise exception 'Video calls require Catcul+.' using errcode = '42501';
  end if;
  select * into c from catcul.voice_calls where id = p_call_id for update;
  if not found or c.ended_at is not null or not catcul.can_send_to_room(c.room_id) then
    raise exception 'Call access denied.' using errcode = '42501';
  end if;
  update catcul.voice_calls set video_mode = true where id = p_call_id and not video_mode;
  return true;
end $$;

create or replace function catcul.authorize_voice_join(p_call_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  c catcul.voice_calls;
  p catcul.profiles;
  v_uid uuid := auth.uid();
begin
  perform catcul.assert_active_account();
  select * into c from catcul.voice_calls where id = p_call_id;
  if not found or c.ended_at is not null or (c.status = 'ringing' and c.started_at < now() - interval '75 seconds') or not catcul.can_send_to_room(c.room_id) then
    raise exception 'Call access denied.' using errcode = '42501';
  end if;
  if not exists(select 1 from catcul.call_participants where call_id = c.id and user_id = v_uid and state = 'accepted') then
    raise exception 'Accept the call before joining.' using errcode = '42501';
  end if;
  select * into p from catcul.profiles where id = v_uid;
  return jsonb_build_object(
    'call_id', c.id,
    'room_id', c.room_id,
    'media_room', 'catcul_' || replace(c.id::text, '-', ''),
    'identity', p.id,
    'name', p.display_name,
    'color', p.color,
    'avatar', p.avatar,
    'video_mode', c.video_mode,
    'can_video', catcul.has_tier('plus', v_uid),
    'tier', catcul.effective_tier(v_uid)
  );
end $$;

-- ---------------------------------------------------------------------
-- 6. Video Posting in Chats + Sticker Exclusivity Guards
-- ---------------------------------------------------------------------
create or replace function catcul.assert_body_stickers_allowed(p_body text, p_user uuid default auth.uid())
returns void language plpgsql stable security definer set search_path = '' as $$
declare
  m text[];
  v_req text;
begin
  if p_body is null or position('[catcul-sticker:' in p_body) = 0 then
    return;
  end if;
  for m in select regexp_matches(p_body, '\[catcul-sticker:([a-z0-9-]+)\]', 'g') loop
    v_req := catcul.sticker_min_tier(m[1]);
    if v_req = 'invalid' then
      raise exception 'Unknown Catcul sticker.';
    end if;
    if not catcul.has_tier(v_req, p_user) then
      raise exception 'That sticker belongs to the % pack.',
        case v_req when 'plus' then 'Catcul+' when 'plusplus' then 'Catcul++' else 'Catcul Premium' end
        using errcode = '42501';
    end if;
  end loop;
end $$;

do $$
declare r record;
begin
  for r in select c.conname from pg_constraint c join pg_class t on t.oid = c.conrelid join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'catcul' and t.relname = 'messages' and c.contype = 'c'
      and (pg_get_constraintdef(c.oid) ilike '%kind%' or pg_get_constraintdef(c.oid) ilike '%deleted_at is not null%') loop
    execute format('alter table catcul.messages drop constraint %I', r.conname);
  end loop;
  for r in select c.conname from pg_constraint c join pg_class t on t.oid = c.conrelid join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'catcul' and t.relname = 'attachments' and c.contype = 'c' and pg_get_constraintdef(c.oid) ilike '%mime_type%' loop
    execute format('alter table catcul.attachments drop constraint %I', r.conname);
  end loop;
end $$;

alter table catcul.messages add constraint messages_kind_check
  check (kind in ('text','photo','audio','file','video'));
alter table catcul.messages add constraint messages_content_check check (
  deleted_at is not null or (
    (kind = 'text' and char_length(btrim(body)) > 0 and attachment_id is null)
    or (kind in ('photo','audio','file','video') and attachment_id is not null)
  )
);

alter table catcul.attachments add constraint attachments_mime_check check (mime_type in (
  'image/jpeg','image/png','image/webp',
  'audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav',
  'video/mp4','video/webm','video/quicktime',
  'application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'text/plain','text/csv','application/zip','application/x-zip-compressed'
));

update storage.buckets
set file_size_limit = 26214400,
    allowed_mime_types = array[
      'image/jpeg','image/png','image/webp',
      'audio/webm','audio/ogg','audio/mp4','audio/mpeg','audio/wav',
      'video/mp4','video/webm','video/quicktime',
      'application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'text/plain','text/csv','application/zip'
    ]
where id = 'catcul-media';

drop policy if exists catcul_attachments_insert on catcul.attachments;
create policy catcul_attachments_insert on catcul.attachments for insert to authenticated with check (
  uploaded_by = (select auth.uid())
  and deleted_at is null
  and catcul.can_send_to_room(room_id)
  and (mime_type not like 'video/%' or catcul.has_tier('premium', (select auth.uid())))
);

drop policy if exists catcul_messages_insert on catcul.messages;
create policy catcul_messages_insert on catcul.messages for insert to authenticated with check (
  sender_id = (select auth.uid())
  and deleted_at is null
  and catcul.can_send_to_room(room_id)
  and (kind <> 'video' or catcul.has_tier('premium', (select auth.uid())))
  and (reply_to is null or exists(select 1 from catcul.messages parent where parent.id = messages.reply_to and parent.room_id = messages.room_id))
  and (attachment_id is null or exists(
    select 1 from catcul.attachments a
    where a.id = messages.attachment_id
      and a.room_id = messages.room_id
      and a.uploaded_by = (select auth.uid())
      and a.deleted_at is null
      and (
        (messages.kind = 'photo' and a.mime_type like 'image/%')
        or (messages.kind = 'audio' and a.mime_type like 'audio/%')
        or (messages.kind = 'file'  and catcul.is_document_mime(a.mime_type))
        or (messages.kind = 'video' and a.mime_type like 'video/%' and catcul.has_tier('premium', (select auth.uid())))
      )
  ))
);

create or replace function catcul.guard_room_message()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  r catcul.rooms;
  v_role text;
begin
  if new.kind = 'video' and not catcul.has_tier('premium', new.sender_id) then
    raise exception 'Posting videos requires Catcul Premium.' using errcode = '42501';
  end if;
  perform catcul.assert_body_stickers_allowed(new.body, new.sender_id);

  select * into r from catcul.rooms where id = new.room_id;
  if not found then return new; end if;
  if r.archived_at is not null then raise exception 'This room has been archived and is read-only.'; end if;
  select role into v_role from catcul.room_members where room_id = new.room_id and user_id = new.sender_id and removed_at is null;
  if r.posting_mode = 'admins' and coalesce(v_role, '') not in ('owner','admin') then
    raise exception 'Only the group admins can post in this room.' using errcode = '42501';
  end if;
  if new.kind = 'file' and not r.allow_files then raise exception 'Files are turned off in this room.'; end if;
  if new.kind in ('photo','audio','video') and not r.allow_media then raise exception 'Photos, videos, and voice notes are turned off in this room.'; end if;
  new.approved := not (r.require_message_approval and coalesce(v_role, '') not in ('owner','admin'));
  return new;
end $$;

create or replace function catcul.edit_message(p_message_id uuid, p_body text)
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  v catcul.messages;
  v_room catcul.rooms;
  v_now timestamptz := now();
begin
  perform catcul.assert_active_account();
  perform catcul.consume_rate('edit_message', 30, 3600);
  select * into v from catcul.messages where id = p_message_id for update;
  if not found then raise exception 'Message not found.' using errcode = 'P0002'; end if;
  select * into v_room from catcul.rooms where id = v.room_id;
  if v_room.archived_at is not null then raise exception 'This room has been archived.'; end if;
  if v.deleted_at is not null then raise exception 'This message was removed.'; end if;
  if v.kind not in ('text','file','video') then raise exception 'Only text, video, and document captions can be edited.'; end if;
  if v.sender_id is distinct from auth.uid() then raise exception 'You can only edit your own messages.' using errcode = '42501'; end if;
  if v.created_at < v_now - interval '24 hours' then raise exception 'Messages can be edited within 24 hours of sending.'; end if;
  if p_body is null or (v.kind = 'text' and char_length(btrim(p_body)) = 0) or char_length(p_body) > 4000 then
    raise exception 'Message needs 1-4000 characters.';
  end if;
  perform catcul.assert_body_stickers_allowed(p_body, auth.uid());
  if p_body = v.body then raise exception 'Nothing changed.'; end if;
  insert into catcul.message_edits(message_id, room_id, old_body, new_body) values (v.id, v.room_id, v.body, left(p_body, 4000));
  update catcul.messages set body = left(p_body, 4000), edited_at = v_now where id = p_message_id;
  return v_now;
end $$;

-- ---------------------------------------------------------------------
-- 7. Catcul Premium: 24-Hour Stories (Photos, Cat Snaps, Videos & Text)
-- ---------------------------------------------------------------------
create table if not exists catcul.stories (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references catcul.profiles(id) on delete cascade,
  media_kind text not null check (media_kind in ('photo','video','text')),
  object_path text check (object_path is null or char_length(object_path) between 10 and 220),
  mime_type text check (mime_type is null or mime_type in ('image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime')),
  byte_size integer check (byte_size is null or byte_size between 1 and 26214400),
  caption text not null default '' check (char_length(caption) <= 280),
  bg_theme text not null default 'meadow' check (char_length(bg_theme) <= 32),
  stickers jsonb not null default '[]'::jsonb check (jsonb_typeof(stickers) = 'array' and jsonb_array_length(stickers) <= 12),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  deleted_at timestamptz,
  check (
    (media_kind = 'text' and object_path is null and char_length(btrim(caption)) > 0)
    or (media_kind = 'photo' and object_path is not null and mime_type like 'image/%' and byte_size is not null)
    or (media_kind = 'video' and object_path is not null and mime_type like 'video/%' and byte_size is not null)
  )
);
create index if not exists stories_active_idx on catcul.stories(expires_at desc, created_at desc) where deleted_at is null;
create index if not exists stories_user_idx on catcul.stories(user_id, created_at desc);

create table if not exists catcul.story_views (
  story_id uuid not null references catcul.stories(id) on delete cascade,
  viewer_id uuid not null default auth.uid() references catcul.profiles(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, viewer_id)
);

create table if not exists catcul.story_reactions (
  story_id uuid not null references catcul.stories(id) on delete cascade,
  user_id uuid not null default auth.uid() references catcul.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('❤️','🔥','😂','😍','👏','✨')),
  created_at timestamptz not null default now(),
  primary key (story_id, user_id)
);

create or replace function catcul.can_view_story_author(p_author uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select catcul.account_is_active()
    and p_author is not null
    and (
      p_author = (select auth.uid())
      or (
        not exists(select 1 from catcul.account_controls where user_id = p_author and suspended)
        and not catcul.blocked_with(p_author)
        and (
          catcul.are_friends(p_author)
          or exists (
            select 1
            from catcul.room_members mine
            join catcul.room_members theirs on theirs.room_id = mine.room_id
            join catcul.rooms r on r.id = mine.room_id
            where mine.user_id = (select auth.uid()) and mine.removed_at is null
              and theirs.user_id = p_author and theirs.removed_at is null
              and coalesce(r.purpose, '') <> 'community'
          )
        )
      )
    );
$$;

-- ---------------------------------------------------------------------
-- 8. Catcul Premium: Campus Spotlight (Short Videos & Cat Snaps)
-- ---------------------------------------------------------------------
create table if not exists catcul.spotlight_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references catcul.profiles(id) on delete cascade,
  media_kind text not null check (media_kind in ('video','photo')),
  object_path text not null check (char_length(object_path) between 10 and 220),
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp','video/mp4','video/webm','video/quicktime')),
  byte_size integer not null check (byte_size between 1 and 26214400),
  title text not null default '' check (char_length(title) <= 100),
  caption text not null default '' check (char_length(caption) <= 500),
  theme_tag text not null default 'campus' check (theme_tag in ('campus','catsnap','study','vibes','funny','creative')),
  views_count integer not null default 0 check (views_count >= 0),
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (
    (media_kind = 'photo' and mime_type like 'image/%')
    or (media_kind = 'video' and mime_type like 'video/%')
  )
);
create index if not exists spotlight_posts_feed_idx on catcul.spotlight_posts(created_at desc) where deleted_at is null;

create table if not exists catcul.spotlight_likes (
  post_id uuid not null references catcul.spotlight_posts(id) on delete cascade,
  user_id uuid not null default auth.uid() references catcul.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists catcul.spotlight_reports (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references catcul.spotlight_posts(id) on delete cascade,
  reporter_id uuid not null default auth.uid() references catcul.profiles(id) on delete cascade,
  reason text not null check (char_length(btrim(reason)) between 3 and 500),
  status text not null default 'open' check (status in ('open','resolved')),
  created_at timestamptz not null default now(),
  unique (post_id, reporter_id)
);

do $$
declare t text;
begin
  foreach t in array array['stories','story_views','story_reactions','spotlight_posts','spotlight_likes','spotlight_reports'] loop
    execute format('alter table catcul.%I enable row level security', t);
    execute format('revoke all on catcul.%I from public, anon, authenticated', t);
    execute format('grant all on catcul.%I to service_role', t);
    execute format('drop policy if exists active_account on catcul.%I', t);
    execute format('create policy active_account on catcul.%I as restrictive for all to authenticated using (catcul.account_is_active()) with check (catcul.account_is_active())', t);
  end loop;
end $$;

grant select on catcul.stories to authenticated;
drop policy if exists stories_select on catcul.stories;
create policy stories_select on catcul.stories for select to authenticated
  using (deleted_at is null and expires_at > now() and catcul.can_view_story_author(user_id));

grant select on catcul.spotlight_posts to authenticated;
drop policy if exists spotlight_select on catcul.spotlight_posts;
create policy spotlight_select on catcul.spotlight_posts for select to authenticated
  using (
    deleted_at is null
    and (
      user_id = (select auth.uid())
      or (
        not exists(select 1 from catcul.account_controls where user_id = spotlight_posts.user_id and suspended)
        and not catcul.blocked_with(user_id)
      )
    )
  );

-- ---------------------------------------------------------------------
-- 9. Storage Guards for Room Videos, Stories & Spotlight
-- ---------------------------------------------------------------------
create or replace function catcul.can_upload_media(p_path text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  parts text[] := string_to_array(coalesce(p_path, ''), '/');
  v_uid uuid := auth.uid();
  v_head text;
  v_user_part text;
  v_file text;
begin
  if v_uid is null or not catcul.account_is_active() or array_length(parts, 1) <> 3 then
    return false;
  end if;
  v_head := parts[1];
  v_user_part := parts[2];
  v_file := lower(parts[3]);
  if v_user_part <> v_uid::text then
    return false;
  end if;

  -- Stories & Spotlight media uploads require Catcul Premium (or Admin).
  if v_head in ('stories','spotlight') then
    if not catcul.has_tier('premium', v_uid) then
      return false;
    end if;
    return v_file ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|jpeg|png|webp|mp4|webm|mov)$';
  end if;

  -- Standard room uploads: <room_uuid>/<user_uuid>/<file>
  if v_head !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  if not catcul.can_send_to_room(v_head::uuid) then
    return false;
  end if;
  -- Video files in rooms (vid-<uuid>.<ext> or .mp4 / .mov) require Catcul Premium.
  if v_file ~ '^vid-' or v_file ~ '\.(mp4|mov)$' then
    return catcul.has_tier('premium', v_uid);
  end if;
  return true;
end $$;

create or replace function catcul.can_read_media(p_path text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  parts text[] := string_to_array(coalesce(p_path, ''), '/');
begin
  if auth.uid() is null or not catcul.account_is_active() then
    return false;
  end if;
  if array_length(parts, 1) = 3 and parts[1] = 'stories' then
    return exists (
      select 1 from catcul.stories s
      where s.object_path = p_path
        and s.deleted_at is null
        and s.expires_at > now()
        and catcul.can_view_story_author(s.user_id)
    );
  end if;
  if array_length(parts, 1) = 3 and parts[1] = 'spotlight' then
    return exists (
      select 1 from catcul.spotlight_posts sp
      where sp.object_path = p_path
        and (
          catcul.is_platform_admin()
          or (
            sp.deleted_at is null
            and (
              sp.user_id = auth.uid()
              or (
                not exists(select 1 from catcul.account_controls where user_id = sp.user_id and suspended)
                and not catcul.blocked_with(sp.user_id)
              )
            )
          )
        )
    );
  end if;
  return exists (
    select 1 from catcul.attachments a
    where a.object_path = p_path
      and a.deleted_at is null
      and catcul.is_member(a.room_id)
  );
end $$;

-- ---------------------------------------------------------------------
-- 10. Stories & Spotlight RPCs (Server-Validated)
-- ---------------------------------------------------------------------
create or replace function catcul.create_story(
  p_media_kind text,
  p_object_path text default null,
  p_mime_type text default null,
  p_byte_size integer default null,
  p_caption text default '',
  p_bg_theme text default 'meadow',
  p_stickers jsonb default '[]'::jsonb
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if not catcul.has_tier('premium', v_uid) then
    raise exception 'Posting Stories requires Catcul Premium.' using errcode = '42501';
  end if;
  perform catcul.consume_rate('create_story', 30, 86400);
  if p_media_kind not in ('photo','video','text') then
    raise exception 'Choose photo, video, or text story.';
  end if;
  if p_media_kind = 'text' then
    if char_length(btrim(coalesce(p_caption, ''))) = 0 then
      raise exception 'Write something for your text story.';
    end if;
    p_object_path := null;
    p_mime_type := null;
    p_byte_size := null;
  else
    if p_object_path is null or split_part(p_object_path, '/', 1) <> 'stories' or split_part(p_object_path, '/', 2) <> v_uid::text then
      raise exception 'Invalid story media path.' using errcode = '42501';
    end if;
  end if;

  insert into catcul.stories(user_id, media_kind, object_path, mime_type, byte_size, caption, bg_theme, stickers)
  values (
    v_uid,
    p_media_kind,
    p_object_path,
    p_mime_type,
    p_byte_size,
    left(btrim(coalesce(p_caption, '')), 280),
    left(coalesce(nullif(btrim(p_bg_theme), ''), 'meadow'), 32),
    coalesce(p_stickers, '[]'::jsonb)
  )
  returning id into v_id;
  return v_id;
end $$;

create or replace function catcul.list_story_feed()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(q) order by (q.user_id = v_uid) desc, q.created_at asc)
    from (
      select
        s.id,
        s.user_id,
        s.media_kind,
        s.object_path,
        s.mime_type,
        s.caption,
        s.bg_theme,
        s.stickers,
        s.created_at,
        s.expires_at,
        p.display_name,
        p.username,
        p.color,
        p.avatar,
        catcul.effective_tier(s.user_id) as author_tier,
        exists(select 1 from catcul.platform_admins a where a.user_id = s.user_id) as author_is_admin,
        (s.user_id = v_uid or exists(select 1 from catcul.story_views sv where sv.story_id = s.id and sv.viewer_id = v_uid)) as viewed,
        (select sr.emoji from catcul.story_reactions sr where sr.story_id = s.id and sr.user_id = v_uid) as my_reaction,
        case when s.user_id = v_uid then (select count(*)::int from catcul.story_views sv where sv.story_id = s.id and sv.viewer_id <> v_uid) else null end as view_count,
        case when s.user_id = v_uid then (select count(*)::int from catcul.story_reactions sr where sr.story_id = s.id) else null end as reaction_count
      from catcul.stories s
      join catcul.profiles p on p.id = s.user_id
      where s.deleted_at is null
        and s.expires_at > now()
        and catcul.can_view_story_author(s.user_id)
      limit 150
    ) q
  ), '[]'::jsonb);
end $$;

create or replace function catcul.mark_story_viewed(p_story_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  s catcul.stories;
begin
  perform catcul.assert_active_account();
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  select * into s from catcul.stories where id = p_story_id and deleted_at is null and expires_at > now();
  if not found or not catcul.can_view_story_author(s.user_id) then return; end if;
  if s.user_id <> auth.uid() then
    insert into catcul.story_views(story_id, viewer_id) values (p_story_id, auth.uid()) on conflict do nothing;
  end if;
end $$;

create or replace function catcul.react_story(p_story_id uuid, p_emoji text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  s catcul.stories;
begin
  perform catcul.assert_active_account();
  perform catcul.consume_rate('react_story', 120, 3600);
  select * into s from catcul.stories where id = p_story_id and deleted_at is null and expires_at > now();
  if not found or not catcul.can_view_story_author(s.user_id) then
    raise exception 'Story not available.' using errcode = 'P0002';
  end if;
  if p_emoji is null or p_emoji = '' then
    delete from catcul.story_reactions where story_id = p_story_id and user_id = auth.uid();
  else
    if p_emoji not in ('❤️','🔥','😂','😍','👏','✨') then raise exception 'Unsupported story reaction.'; end if;
    insert into catcul.story_reactions(story_id, user_id, emoji) values (p_story_id, auth.uid(), p_emoji)
    on conflict (story_id, user_id) do update set emoji = excluded.emoji, created_at = now();
  end if;
end $$;

create or replace function catcul.delete_story(p_story_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  s catcul.stories;
begin
  perform catcul.assert_active_account();
  select * into s from catcul.stories where id = p_story_id for update;
  if not found then return; end if;
  if s.user_id is distinct from auth.uid() and not catcul.is_platform_admin() then
    raise exception 'You can only remove your own story.' using errcode = '42501';
  end if;
  update catcul.stories set deleted_at = now() where id = p_story_id and deleted_at is null;
end $$;

create or replace function catcul.create_spotlight_post(
  p_media_kind text,
  p_object_path text,
  p_mime_type text,
  p_byte_size integer,
  p_title text default '',
  p_caption text default '',
  p_theme_tag text default 'campus'
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if not catcul.has_tier('premium', v_uid) then
    raise exception 'Posting to Spotlight requires Catcul Premium.' using errcode = '42501';
  end if;
  perform catcul.consume_rate('create_spotlight', 20, 86400);
  if p_media_kind not in ('video','photo') then
    raise exception 'Spotlight accepts videos and snaps.';
  end if;
  if p_object_path is null or split_part(p_object_path, '/', 1) <> 'spotlight' or split_part(p_object_path, '/', 2) <> v_uid::text then
    raise exception 'Invalid Spotlight media path.' using errcode = '42501';
  end if;
  if p_theme_tag not in ('campus','catsnap','study','vibes','funny','creative') then
    p_theme_tag := 'campus';
  end if;
  insert into catcul.spotlight_posts(user_id, media_kind, object_path, mime_type, byte_size, title, caption, theme_tag)
  values (
    v_uid,
    p_media_kind,
    p_object_path,
    p_mime_type,
    p_byte_size,
    left(btrim(coalesce(p_title, '')), 100),
    left(btrim(coalesce(p_caption, '')), 500),
    p_theme_tag
  )
  returning id into v_id;
  return v_id;
end $$;

create or replace function catcul.list_spotlight_feed(
  p_filter text default 'all',
  p_limit integer default 30,
  p_offset integer default 0
)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_lim integer := greatest(1, least(coalesce(p_limit, 30), 60));
  v_off integer := greatest(0, least(coalesce(p_offset, 0), 5000));
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(q))
    from (
      select
        sp.id,
        sp.user_id,
        sp.media_kind,
        sp.object_path,
        sp.mime_type,
        sp.title,
        sp.caption,
        sp.theme_tag,
        sp.views_count,
        sp.created_at,
        p.display_name,
        p.username,
        p.color,
        p.avatar,
        catcul.effective_tier(sp.user_id) as author_tier,
        exists(select 1 from catcul.platform_admins a where a.user_id = sp.user_id) as author_is_admin,
        (select count(*)::int from catcul.spotlight_likes sl where sl.post_id = sp.id) as likes_count,
        exists(select 1 from catcul.spotlight_likes sl where sl.post_id = sp.id and sl.user_id = v_uid) as liked_by_me
      from catcul.spotlight_posts sp
      join catcul.profiles p on p.id = sp.user_id
      where sp.deleted_at is null
        and (
          sp.user_id = v_uid
          or (
            not exists(select 1 from catcul.account_controls where user_id = sp.user_id and suspended)
            and not catcul.blocked_with(sp.user_id)
          )
        )
        and (
          coalesce(p_filter, 'all') = 'all'
          or (p_filter = 'video' and sp.media_kind = 'video')
          or (p_filter = 'catsnap' and (sp.theme_tag = 'catsnap' or sp.media_kind = 'photo'))
          or (p_filter = 'mine' and sp.user_id = v_uid)
          or (p_filter = 'trending')
        )
      order by
        case when p_filter = 'trending'
          then (select count(*) from catcul.spotlight_likes sl where sl.post_id = sp.id) * 3 + sp.views_count
          else 0
        end desc,
        sp.created_at desc,
        sp.id desc
      limit v_lim offset v_off
    ) q
  ), '[]'::jsonb);
end $$;

create or replace function catcul.toggle_spotlight_like(p_post_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  sp catcul.spotlight_posts;
  v_liked boolean;
begin
  perform catcul.assert_active_account();
  perform catcul.consume_rate('spotlight_like', 180, 3600);
  select * into sp from catcul.spotlight_posts where id = p_post_id and deleted_at is null;
  if not found or catcul.blocked_with(sp.user_id) then
    raise exception 'Spotlight post unavailable.' using errcode = 'P0002';
  end if;
  if exists(select 1 from catcul.spotlight_likes where post_id = p_post_id and user_id = auth.uid()) then
    delete from catcul.spotlight_likes where post_id = p_post_id and user_id = auth.uid();
    v_liked := false;
  else
    insert into catcul.spotlight_likes(post_id, user_id) values (p_post_id, auth.uid()) on conflict do nothing;
    v_liked := true;
  end if;
  return jsonb_build_object(
    'liked', v_liked,
    'likes_count', (select count(*)::int from catcul.spotlight_likes where post_id = p_post_id)
  );
end $$;

create or replace function catcul.record_spotlight_view(p_post_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform catcul.assert_active_account();
  if auth.uid() is null then return; end if;
  update catcul.spotlight_posts set views_count = views_count + 1
  where id = p_post_id and deleted_at is null and user_id <> auth.uid();
end $$;

create or replace function catcul.delete_spotlight_post(p_post_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  sp catcul.spotlight_posts;
begin
  perform catcul.assert_active_account();
  select * into sp from catcul.spotlight_posts where id = p_post_id for update;
  if not found then return; end if;
  if sp.user_id is distinct from auth.uid() and not catcul.is_platform_admin() then
    raise exception 'Only the author or platform administrator can remove this Spotlight post.' using errcode = '42501';
  end if;
  update catcul.spotlight_posts set deleted_at = now() where id = p_post_id and deleted_at is null;
  update catcul.spotlight_reports set status = 'resolved' where post_id = p_post_id and status = 'open';
  if catcul.is_platform_admin() and sp.user_id is distinct from auth.uid() then
    insert into catcul.admin_audit(actor_id, action, target_id, detail)
    values (auth.uid(), 'remove_spotlight', p_post_id, jsonb_build_object('author', sp.user_id));
  end if;
end $$;

create or replace function catcul.report_spotlight_post(p_post_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform catcul.assert_active_account();
  perform catcul.consume_rate('report_spotlight', 15, 86400);
  if char_length(btrim(coalesce(p_reason, ''))) not between 3 and 500 then
    raise exception 'Provide a brief reason (3–500 characters).';
  end if;
  if not exists(select 1 from catcul.spotlight_posts where id = p_post_id and deleted_at is null) then
    raise exception 'Spotlight post not found.' using errcode = 'P0002';
  end if;
  insert into catcul.spotlight_reports(post_id, reporter_id, reason)
  values (p_post_id, auth.uid(), btrim(p_reason))
  on conflict (post_id, reporter_id) do update set reason = excluded.reason, status = 'open', created_at = now();
end $$;

-- ---------------------------------------------------------------------
-- 11. Owner / Platform Admin Billing & Moderation Controls
-- ---------------------------------------------------------------------
create or replace function catcul.admin_billing_overview()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform catcul.require_platform_admin();
  return jsonb_build_object(
    'config', (select to_jsonb(c) from catcul.billing_config c where c.id = 1),
    'plans', coalesce((select jsonb_agg(to_jsonb(p) order by catcul.tier_rank(p.tier)) from catcul.billing_plans p), '[]'::jsonb),
    'counts', jsonb_build_object(
      'plus', (select count(*)::int from catcul.user_subscriptions where tier = 'plus' and status in ('active','trialing','past_due')),
      'plusplus', (select count(*)::int from catcul.user_subscriptions where tier = 'plusplus' and status in ('active','trialing','past_due')),
      'premium', (select count(*)::int from catcul.user_subscriptions where tier = 'premium' and status in ('active','trialing','past_due')),
      'grants', (select count(*)::int from catcul.tier_grants where expires_at is null or expires_at > now()),
      'spotlight_posts', (select count(*)::int from catcul.spotlight_posts where deleted_at is null),
      'spotlight_reports_open', (select count(*)::int from catcul.spotlight_reports where status = 'open'),
      'stories_active', (select count(*)::int from catcul.stories where deleted_at is null and expires_at > now())
    ),
    'grants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', g.user_id,
        'username', p.username,
        'display_name', p.display_name,
        'tier', g.tier,
        'note', g.note,
        'expires_at', g.expires_at,
        'updated_at', g.updated_at
      ) order by g.updated_at desc)
      from catcul.tier_grants g
      join catcul.profiles p on p.id = g.user_id
    ), '[]'::jsonb),
    'subscriptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', s.user_id,
        'username', p.username,
        'display_name', p.display_name,
        'tier', s.tier,
        'status', s.status,
        'billing_interval', s.billing_interval,
        'current_period_end', s.current_period_end,
        'cancel_at_period_end', s.cancel_at_period_end,
        'updated_at', s.updated_at
      ) order by s.updated_at desc)
      from (select * from catcul.user_subscriptions order by updated_at desc limit 40) s
      join catcul.profiles p on p.id = s.user_id
    ), '[]'::jsonb),
    'spotlight_reports', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', r.id,
        'post_id', r.post_id,
        'reason', r.reason,
        'created_at', r.created_at,
        'reporter_username', rp.username,
        'author_username', ap.username,
        'title', sp.title,
        'caption', sp.caption,
        'media_kind', sp.media_kind
      ) order by r.created_at desc)
      from catcul.spotlight_reports r
      join catcul.spotlight_posts sp on sp.id = r.post_id
      join catcul.profiles rp on rp.id = r.reporter_id
      join catcul.profiles ap on ap.id = sp.user_id
      where r.status = 'open' and sp.deleted_at is null
    ), '[]'::jsonb)
  );
end $$;

drop function if exists catcul.admin_save_billing(text, text, text, jsonb);

create or replace function catcul.admin_save_billing(
  p_environment text,
  p_client_token text,
  p_currency text,
  p_plans jsonb,
  p_deepar_license_key text default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  item jsonb;
  v_tier text;
  v_tok text := btrim(coalesce(p_client_token, ''));
  v_cur text := upper(btrim(coalesce(p_currency, 'USD')));
  v_dar text := case when p_deepar_license_key is null then null else btrim(p_deepar_license_key) end;
begin
  perform catcul.require_platform_admin();
  if p_environment not in ('sandbox','production') then
    raise exception 'Environment must be sandbox or production.';
  end if;
  if v_tok <> '' and v_tok !~ '^(test|live)_[A-Za-z0-9_]{10,180}$' then
    raise exception 'Paddle client-side token must start with test_ or live_ (never paste a secret API key here).';
  end if;
  if v_cur !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a 3-letter ISO code such as USD, EUR, or GBP.';
  end if;
  if v_dar is not null then
    if char_length(v_dar) > 320 then
      raise exception 'DeepAR Web license key must be 320 characters or fewer.';
    end if;
    if v_dar ~ '^(pdl_|sb_secret_|sk_|whsec_|ntfset_)' then
      raise exception 'Only a public domain-bound DeepAR Web license key belongs here — never paste secret API keys.';
    end if;
  end if;

  update catcul.billing_config
  set environment = p_environment,
      client_token = v_tok,
      currency = v_cur,
      deepar_license_key = coalesce(v_dar, deepar_license_key),
      updated_at = now(),
      updated_by = auth.uid()
  where id = 1;

  if p_plans is not null and jsonb_typeof(p_plans) = 'array' then
    for item in select * from jsonb_array_elements(p_plans) loop
      v_tier := coalesce(item->>'tier', '');
      if v_tier in ('plus','plusplus','premium') then
        update catcul.billing_plans
        set name = coalesce(nullif(left(btrim(coalesce(item->>'name', '')), 40), ''), name),
            tagline = left(btrim(coalesce(item->>'tagline', tagline)), 180),
            monthly_price_display = coalesce(nullif(left(btrim(coalesce(item->>'monthly_price_display', '')), 24), ''), monthly_price_display),
            yearly_price_display  = coalesce(nullif(left(btrim(coalesce(item->>'yearly_price_display', '')), 24), ''), yearly_price_display),
            monthly_price_id      = btrim(coalesce(item->>'monthly_price_id', '')),
            yearly_price_id       = btrim(coalesce(item->>'yearly_price_id', '')),
            updated_at = now()
        where tier = v_tier;
      end if;
    end loop;
  end if;

  insert into catcul.admin_audit(actor_id, action, detail)
  values (auth.uid(), 'billing_settings', jsonb_build_object(
    'environment', p_environment,
    'currency', v_cur,
    'token_set', v_tok <> '',
    'deepar_set', coalesce(v_dar, '') <> ''
  ));
end $$;

create or replace function catcul.admin_set_tier_grant(
  p_username text,
  p_tier text,
  p_note text default '',
  p_days integer default null
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_target uuid;
  v_clean text := lower(regexp_replace(btrim(coalesce(p_username, '')), '^@+', ''));
begin
  perform catcul.require_platform_admin();
  select id into v_target from catcul.profiles where lower(username) = v_clean;
  if v_target is null then
    raise exception 'No student found with username @%.', v_clean using errcode = 'P0002';
  end if;
  if coalesce(p_tier, 'free') = 'free' then
    delete from catcul.tier_grants where user_id = v_target;
    insert into catcul.admin_audit(actor_id, action, target_id, detail)
    values (auth.uid(), 'revoke_tier_grant', v_target, jsonb_build_object('username', v_clean));
    return;
  end if;
  if p_tier not in ('plus','plusplus','premium') then
    raise exception 'Tier must be free, plus, plusplus, or premium.';
  end if;
  insert into catcul.tier_grants(user_id, tier, note, expires_at, granted_by, updated_at)
  values (
    v_target,
    p_tier,
    left(btrim(coalesce(p_note, '')), 240),
    case when p_days is not null and p_days > 0 then now() + make_interval(days => least(p_days, 3650)) else null end,
    auth.uid(),
    now()
  )
  on conflict (user_id) do update set
    tier = excluded.tier,
    note = excluded.note,
    expires_at = excluded.expires_at,
    granted_by = auth.uid(),
    updated_at = now();

  insert into catcul.admin_audit(actor_id, action, target_id, detail)
  values (auth.uid(), 'grant_tier', v_target, jsonb_build_object('tier', p_tier, 'days', p_days, 'note', left(btrim(coalesce(p_note, '')), 120)));
end $$;

-- ---------------------------------------------------------------------
-- 12. Grants & Schema Reload
-- ---------------------------------------------------------------------
revoke all on function
  catcul.tier_rank(text),
  catcul.effective_tier(uuid),
  catcul.has_tier(text, uuid),
  catcul.theme_min_tier(text),
  catcul.wallpaper_min_tier(text),
  catcul.sticker_min_tier(text),
  catcul.effective_app_theme(uuid),
  catcul.set_app_theme(text),
  catcul.get_public_pricing(),
  catcul.get_my_entitlements(),
  catcul.public_user_tiers(uuid[]),
  catcul.enable_call_video(uuid),
  catcul.assert_body_stickers_allowed(text, uuid),
  catcul.can_view_story_author(uuid),
  catcul.create_story(text, text, text, integer, text, text, jsonb),
  catcul.list_story_feed(),
  catcul.mark_story_viewed(uuid),
  catcul.react_story(uuid, text),
  catcul.delete_story(uuid),
  catcul.create_spotlight_post(text, text, text, integer, text, text, text),
  catcul.list_spotlight_feed(text, integer, integer),
  catcul.toggle_spotlight_like(uuid),
  catcul.record_spotlight_view(uuid),
  catcul.delete_spotlight_post(uuid),
  catcul.report_spotlight_post(uuid, text),
  catcul.admin_billing_overview(),
  catcul.admin_save_billing(text, text, text, jsonb, text),
  catcul.admin_set_tier_grant(text, text, text, integer)
from public, anon, authenticated;

grant execute on function catcul.tier_rank(text), catcul.get_public_pricing() to anon, authenticated, service_role;

grant execute on function
  catcul.effective_tier(uuid),
  catcul.has_tier(text, uuid),
  catcul.theme_min_tier(text),
  catcul.wallpaper_min_tier(text),
  catcul.sticker_min_tier(text),
  catcul.effective_app_theme(uuid),
  catcul.set_app_theme(text),
  catcul.get_my_entitlements(),
  catcul.public_user_tiers(uuid[]),
  catcul.enable_call_video(uuid),
  catcul.assert_body_stickers_allowed(text, uuid),
  catcul.can_view_story_author(uuid),
  catcul.create_story(text, text, text, integer, text, text, jsonb),
  catcul.list_story_feed(),
  catcul.mark_story_viewed(uuid),
  catcul.react_story(uuid, text),
  catcul.delete_story(uuid),
  catcul.create_spotlight_post(text, text, text, integer, text, text, text),
  catcul.list_spotlight_feed(text, integer, integer),
  catcul.toggle_spotlight_like(uuid),
  catcul.record_spotlight_view(uuid),
  catcul.delete_spotlight_post(uuid),
  catcul.report_spotlight_post(uuid, text),
  catcul.admin_billing_overview(),
  catcul.admin_save_billing(text, text, text, jsonb, text),
  catcul.admin_set_tier_grant(text, text, text, integer)
to authenticated, service_role;

-- Advanced Campus Spotlight: comments, bookmarks/saves, sound labels, friends/saved filters & live search
alter table catcul.spotlight_posts
  add column if not exists sound_label text not null default '',
  add column if not exists allow_comments boolean not null default true;

create table if not exists catcul.spotlight_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references catcul.spotlight_posts(id) on delete cascade,
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 400),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists spotlight_comments_post_idx
  on catcul.spotlight_comments (post_id, created_at desc)
  where deleted_at is null;

alter table catcul.spotlight_comments enable row level security;

create table if not exists catcul.spotlight_bookmarks (
  post_id uuid not null references catcul.spotlight_posts(id) on delete cascade,
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create index if not exists spotlight_bookmarks_user_idx
  on catcul.spotlight_bookmarks (user_id, created_at desc);

alter table catcul.spotlight_bookmarks enable row level security;

drop policy if exists spotlight_comments_select on catcul.spotlight_comments;
create policy spotlight_comments_select on catcul.spotlight_comments
  for select to authenticated
  using (deleted_at is null and not catcul.blocked_with(user_id));

drop policy if exists spotlight_bookmarks_own on catcul.spotlight_bookmarks;
create policy spotlight_bookmarks_own on catcul.spotlight_bookmarks
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop function if exists catcul.create_spotlight_post(text, text, text, integer, text, text, text);
create or replace function catcul.create_spotlight_post(
  p_media_kind text,
  p_object_path text,
  p_mime_type text,
  p_byte_size integer,
  p_title text default ''::text,
  p_caption text default ''::text,
  p_theme_tag text default 'campus'::text,
  p_sound_label text default ''::text,
  p_allow_comments boolean default true
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if not catcul.has_tier('premium', v_uid) then
    raise exception 'Posting to Spotlight requires Catcul Premium.' using errcode = '42501';
  end if;
  perform catcul.consume_rate('create_spotlight', 20, 86400);
  if p_media_kind not in ('video', 'photo') then
    raise exception 'Spotlight accepts videos and snaps.';
  end if;
  if p_object_path is null or split_part(p_object_path, '/', 1) <> 'spotlight' or split_part(p_object_path, '/', 2) <> v_uid::text then
    raise exception 'Invalid Spotlight media path.' using errcode = '42501';
  end if;
  if p_theme_tag not in ('campus', 'catsnap', 'study', 'vibes', 'funny', 'creative') then
    p_theme_tag := 'campus';
  end if;
  insert into catcul.spotlight_posts(
    user_id, media_kind, object_path, mime_type, byte_size, title, caption, theme_tag, sound_label, allow_comments
  )
  values (
    v_uid, p_media_kind, p_object_path, p_mime_type, p_byte_size,
    left(btrim(coalesce(p_title, '')), 100),
    left(btrim(coalesce(p_caption, '')), 500),
    p_theme_tag,
    left(btrim(coalesce(p_sound_label, '')), 60),
    coalesce(p_allow_comments, true)
  )
  returning id into v_id;
  return v_id;
end $$;

drop function if exists catcul.list_spotlight_feed(text, integer, integer);
create or replace function catcul.list_spotlight_feed(
  p_filter text default 'all'::text,
  p_limit integer default 30,
  p_offset integer default 0,
  p_search text default ''::text
)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_lim integer := greatest(1, least(coalesce(p_limit, 30), 60));
  v_off integer := greatest(0, least(coalesce(p_offset, 0), 5000));
  v_q text := lower(btrim(coalesce(p_search, '')));
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(q))
    from (
      select
        sp.id, sp.user_id, sp.media_kind, sp.object_path, sp.mime_type,
        sp.title, sp.caption, sp.theme_tag, sp.sound_label, sp.allow_comments,
        sp.views_count, sp.created_at,
        p.display_name, p.username, p.color, p.avatar,
        catcul.effective_tier(sp.user_id) as author_tier,
        exists(select 1 from catcul.platform_admins a where a.user_id = sp.user_id) as author_is_admin,
        (select count(*)::int from catcul.spotlight_likes sl where sl.post_id = sp.id) as likes_count,
        exists(select 1 from catcul.spotlight_likes sl where sl.post_id = sp.id and sl.user_id = v_uid) as liked_by_me,
        (select count(*)::int from catcul.spotlight_comments sc where sc.post_id = sp.id and sc.deleted_at is null) as comments_count,
        (select count(*)::int from catcul.spotlight_bookmarks sb where sb.post_id = sp.id) as saves_count,
        exists(select 1 from catcul.spotlight_bookmarks sb where sb.post_id = sp.id and sb.user_id = v_uid) as bookmarked_by_me
      from catcul.spotlight_posts sp
      join catcul.profiles p on p.id = sp.user_id
      where sp.deleted_at is null
        and (
          sp.user_id = v_uid
          or (
            not exists(select 1 from catcul.account_controls where user_id = sp.user_id and suspended)
            and not catcul.blocked_with(sp.user_id)
          )
        )
        and (
          coalesce(p_filter, 'all') in ('all', 'trending')
          or (p_filter = 'video' and sp.media_kind = 'video')
          or (p_filter = 'catsnap' and (sp.theme_tag = 'catsnap' or sp.media_kind = 'photo'))
          or (p_filter in ('study', 'vibes', 'funny', 'creative', 'campus') and sp.theme_tag = p_filter)
          or (p_filter = 'mine' and sp.user_id = v_uid)
          or (p_filter = 'saved' and exists(select 1 from catcul.spotlight_bookmarks sb where sb.post_id = sp.id and sb.user_id = v_uid))
          or (p_filter = 'friends' and (
            sp.user_id = v_uid or exists(
              select 1 from catcul.friendships f
              where f.user_low = least(v_uid, sp.user_id)
                and f.user_high = greatest(v_uid, sp.user_id)
                and f.status = 'accepted'
            )
          ))
        )
        and (
          v_q = ''
          or lower(sp.title) like '%' || v_q || '%'
          or lower(sp.caption) like '%' || v_q || '%'
          or lower(sp.theme_tag) like '%' || v_q || '%'
          or lower(coalesce(p.username, '')) like '%' || v_q || '%'
          or lower(coalesce(p.display_name, '')) like '%' || v_q || '%'
        )
      order by
        case when p_filter = 'trending'
          then (select count(*) from catcul.spotlight_likes sl where sl.post_id = sp.id) * 4
             + (select count(*) from catcul.spotlight_comments sc where sc.post_id = sp.id and sc.deleted_at is null) * 5
             + sp.views_count
          else 0
        end desc,
        sp.created_at desc, sp.id desc
      limit v_lim offset v_off
    ) q
  ), '[]'::jsonb);
end $$;

create or replace function catcul.toggle_spotlight_bookmark(p_post_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  sp catcul.spotlight_posts;
  v_saved boolean;
begin
  perform catcul.assert_active_account();
  perform catcul.consume_rate('spotlight_bookmark', 180, 3600);
  select * into sp from catcul.spotlight_posts where id = p_post_id and deleted_at is null;
  if not found or catcul.blocked_with(sp.user_id) then
    raise exception 'Spotlight post unavailable.' using errcode = 'P0002';
  end if;
  if exists(select 1 from catcul.spotlight_bookmarks where post_id = p_post_id and user_id = auth.uid()) then
    delete from catcul.spotlight_bookmarks where post_id = p_post_id and user_id = auth.uid();
    v_saved := false;
  else
    insert into catcul.spotlight_bookmarks(post_id, user_id) values (p_post_id, auth.uid()) on conflict do nothing;
    v_saved := true;
  end if;
  return jsonb_build_object(
    'saved', v_saved,
    'saves_count', (select count(*)::int from catcul.spotlight_bookmarks where post_id = p_post_id)
  );
end $$;

create or replace function catcul.list_spotlight_comments(p_post_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(q))
    from (
      select
        sc.id, sc.post_id, sc.user_id, sc.body, sc.created_at,
        p.display_name, p.username, p.color, p.avatar,
        catcul.effective_tier(sc.user_id) as author_tier,
        exists(select 1 from catcul.platform_admins a where a.user_id = sc.user_id) as author_is_admin
      from catcul.spotlight_comments sc
      join catcul.profiles p on p.id = sc.user_id
      where sc.post_id = p_post_id and sc.deleted_at is null and not catcul.blocked_with(sc.user_id)
      order by sc.created_at asc
      limit 120
    ) q
  ), '[]'::jsonb);
end $$;

create or replace function catcul.add_spotlight_comment(p_post_id uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  sp catcul.spotlight_posts;
  v_clean text := btrim(coalesce(p_body, ''));
  v_cid uuid;
  v_out jsonb;
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  perform catcul.consume_rate('spotlight_comment', 60, 3600);
  if char_length(v_clean) < 1 or char_length(v_clean) > 400 then
    raise exception 'Comment must be between 1 and 400 characters.';
  end if;
  select * into sp from catcul.spotlight_posts where id = p_post_id and deleted_at is null;
  if not found or catcul.blocked_with(sp.user_id) then
    raise exception 'Spotlight post unavailable.' using errcode = 'P0002';
  end if;
  if not sp.allow_comments and sp.user_id <> v_uid then
    raise exception 'Comments are turned off for this Spotlight.';
  end if;
  insert into catcul.spotlight_comments(post_id, user_id, body)
  values (p_post_id, v_uid, v_clean)
  returning id into v_cid;
  select to_jsonb(q) into v_out
  from (
    select
      sc.id, sc.post_id, sc.user_id, sc.body, sc.created_at,
      p.display_name, p.username, p.color, p.avatar,
      catcul.effective_tier(sc.user_id) as author_tier,
      exists(select 1 from catcul.platform_admins a where a.user_id = sc.user_id) as author_is_admin,
      (select count(*)::int from catcul.spotlight_comments c2 where c2.post_id = p_post_id and c2.deleted_at is null) as comments_count
    from catcul.spotlight_comments sc
    join catcul.profiles p on p.id = sc.user_id
    where sc.id = v_cid
  ) q;
  return v_out;
end $$;

create or replace function catcul.delete_spotlight_comment(p_comment_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  sc catcul.spotlight_comments;
  v_post_owner uuid;
begin
  perform catcul.assert_active_account();
  select * into sc from catcul.spotlight_comments where id = p_comment_id for update;
  if not found then return jsonb_build_object('ok', true); end if;
  select user_id into v_post_owner from catcul.spotlight_posts where id = sc.post_id;
  if sc.user_id is distinct from v_uid and v_post_owner is distinct from v_uid and not catcul.is_platform_admin() then
    raise exception 'You cannot delete this comment.' using errcode = '42501';
  end if;
  update catcul.spotlight_comments set deleted_at = now() where id = p_comment_id and deleted_at is null;
  return jsonb_build_object(
    'ok', true,
    'post_id', sc.post_id,
    'comments_count', (select count(*)::int from catcul.spotlight_comments c2 where c2.post_id = sc.post_id and c2.deleted_at is null)
  );
end $$;

revoke all on function
  catcul.create_spotlight_post(text, text, text, integer, text, text, text, text, boolean),
  catcul.list_spotlight_feed(text, integer, integer, text),
  catcul.toggle_spotlight_bookmark(uuid),
  catcul.list_spotlight_comments(uuid),
  catcul.add_spotlight_comment(uuid, text),
  catcul.delete_spotlight_comment(uuid)
from public;

grant execute on function
  catcul.create_spotlight_post(text, text, text, integer, text, text, text, text, boolean),
  catcul.list_spotlight_feed(text, integer, integer, text),
  catcul.toggle_spotlight_bookmark(uuid),
  catcul.list_spotlight_comments(uuid),
  catcul.add_spotlight_comment(uuid, text),
  catcul.delete_spotlight_comment(uuid)
to authenticated, service_role;

-- Phase 2 Advanced Campus Spotlight: Multi-vibe reactions, post editing & admin report dismissal
create table if not exists catcul.spotlight_reactions (
  post_id uuid not null references catcul.spotlight_posts(id) on delete cascade,
  user_id uuid not null references catcul.profiles(id) on delete cascade,
  emoji text not null check (emoji in ('🔥', '😂', '🤯', '👏')),
  created_at timestamptz not null default now(),
  primary key (post_id, user_id, emoji)
);

create index if not exists spotlight_reactions_post_idx
  on catcul.spotlight_reactions (post_id);

alter table catcul.spotlight_reactions enable row level security;

drop policy if exists spotlight_reactions_select on catcul.spotlight_reactions;
create policy spotlight_reactions_select on catcul.spotlight_reactions
  for select to authenticated
  using (not catcul.blocked_with(user_id));

create or replace function catcul.toggle_spotlight_reaction(p_post_id uuid, p_emoji text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  sp catcul.spotlight_posts;
  v_active boolean;
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  perform catcul.consume_rate('spotlight_reaction', 240, 3600);
  if p_emoji not in ('🔥', '😂', '🤯', '👏') then
    raise exception 'Unsupported Spotlight reaction.';
  end if;
  select * into sp from catcul.spotlight_posts where id = p_post_id and deleted_at is null;
  if not found or catcul.blocked_with(sp.user_id) then
    raise exception 'Spotlight post unavailable.' using errcode = 'P0002';
  end if;
  if exists(select 1 from catcul.spotlight_reactions where post_id = p_post_id and user_id = v_uid and emoji = p_emoji) then
    delete from catcul.spotlight_reactions where post_id = p_post_id and user_id = v_uid and emoji = p_emoji;
    v_active := false;
  else
    insert into catcul.spotlight_reactions(post_id, user_id, emoji)
    values (p_post_id, v_uid, p_emoji) on conflict do nothing;
    v_active := true;
  end if;
  return jsonb_build_object(
    'active', v_active,
    'emoji', p_emoji,
    'reactions', coalesce((
      select jsonb_object_agg(emoji, cnt)
      from (select emoji, count(*)::int as cnt from catcul.spotlight_reactions where post_id = p_post_id group by emoji) agg
    ), '{}'::jsonb),
    'my_reactions', coalesce((
      select jsonb_agg(emoji order by emoji) from catcul.spotlight_reactions where post_id = p_post_id and user_id = v_uid
    ), '[]'::jsonb)
  );
end $$;

create or replace function catcul.update_spotlight_post(
  p_post_id uuid,
  p_title text default ''::text,
  p_caption text default ''::text,
  p_theme_tag text default 'campus'::text,
  p_sound_label text default ''::text,
  p_allow_comments boolean default true
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  sp catcul.spotlight_posts;
  v_tag text := coalesce(p_theme_tag, 'campus');
begin
  perform catcul.assert_active_account();
  if v_uid is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  perform catcul.consume_rate('update_spotlight', 60, 3600);
  select * into sp from catcul.spotlight_posts where id = p_post_id and deleted_at is null for update;
  if not found then raise exception 'Spotlight post not found.' using errcode = 'P0002'; end if;
  if sp.user_id is distinct from v_uid and not catcul.is_platform_admin() then
    raise exception 'Only the author can edit this Spotlight post.' using errcode = '42501';
  end if;
  if v_tag not in ('campus', 'catsnap', 'study', 'vibes', 'funny', 'creative') then v_tag := 'campus'; end if;
  update catcul.spotlight_posts
  set title = left(btrim(coalesce(p_title, '')), 100),
      caption = left(btrim(coalesce(p_caption, '')), 500),
      theme_tag = v_tag,
      sound_label = left(btrim(coalesce(p_sound_label, '')), 60),
      allow_comments = coalesce(p_allow_comments, true)
  where id = p_post_id
  returning * into sp;
  return jsonb_build_object(
    'id', sp.id, 'title', sp.title, 'caption', sp.caption,
    'theme_tag', sp.theme_tag, 'sound_label', sp.sound_label, 'allow_comments', sp.allow_comments
  );
end $$;

create or replace function catcul.dismiss_spotlight_report(p_report_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform catcul.require_platform_admin();
  update catcul.spotlight_reports set status = 'dismissed' where id = p_report_id and status = 'open';
  return jsonb_build_object('ok', true);
end $$;

revoke all on function
  catcul.toggle_spotlight_reaction(uuid, text),
  catcul.update_spotlight_post(uuid, text, text, text, text, boolean),
  catcul.dismiss_spotlight_report(uuid)
from public;

grant execute on function
  catcul.toggle_spotlight_reaction(uuid, text),
  catcul.update_spotlight_post(uuid, text, text, text, text, boolean),
  catcul.dismiss_spotlight_report(uuid)
to authenticated, service_role;

-- =====================================================================
-- Friends Games Area (Squad Arcade, Offline HTML Slot & Party Lobbies)
-- =====================================================================
create table if not exists catcul.arcade_games (
  slug text primary key check (slug ~ '^[a-z0-9-]{2,40}$'),
  title text not null check (char_length(trim(title)) between 1 and 80),
  subtitle text not null default '' check (char_length(subtitle) <= 220),
  genre text not null default 'Multiplayer' check (char_length(genre) <= 40),
  launch_url text not null default '' check (char_length(launch_url) <= 1000),
  cover_style text not null default 'custom' check (char_length(cover_style) <= 30),
  supports_party_code boolean not null default true,
  enabled boolean not null default true,
  sort_order integer not null default 10,
  updated_at timestamptz not null default now()
);

alter table catcul.arcade_games enable row level security;
drop policy if exists arcade_games_select on catcul.arcade_games;
create policy arcade_games_select on catcul.arcade_games
  for select to authenticated using (enabled = true or catcul.is_platform_admin());

insert into catcul.arcade_games (slug, title, subtitle, genre, launch_url, cover_style, supports_party_code, enabled, sort_order)
values
  ('veck-io', 'Veck.io', 'Fast-paced 3D arena FPS — 1v1, 2v2, Gun Game & Free-For-All right in your browser.', 'Arena FPS', 'https://veck.io/', 'veck', true, true, 1),
  ('poxel-io', 'Poxel.io', 'Blocky movement shooter — slide, dash, strafe & share private squad room codes.', 'Movement FPS', 'https://poxel.io/', 'poxel', true, true, 2),
  ('eaglercraft-112', 'Eaglercraft 1.12.2', 'Voxel survival, PvP & LAN worlds — ready for Eaglercraft_1.12.2_u3_Offline.html.', 'Voxel 1.12.2', 'games/eaglercraft.html?slot=eaglercraft-112', 'voxel', true, true, 3),
  ('eaglercraft-262', 'Eaglercraft 26.2', 'Latest voxel sandbox & multiplayer worlds — ready for eaglercraft-26.2-fe8f1237.html.', 'Voxel 26.2', 'games/eaglercraft.html?slot=eaglercraft-262', 'custom', true, true, 4)
on conflict (slug) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('catcul-games', 'catcul-games', true, 52428800, array['application/gzip', 'application/x-gzip', 'application/octet-stream', 'application/json'])
on conflict (id) do update set public = true, file_size_limit = 52428800, allowed_mime_types = array['application/gzip', 'application/x-gzip', 'application/octet-stream', 'application/json'];

create table if not exists catcul.arcade_lobbies (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users(id) on delete cascade,
  game_slug text not null references catcul.arcade_games(slug) on delete cascade,
  party_code text not null check (char_length(trim(party_code)) between 1 and 80),
  note text not null default '' check (char_length(note) <= 160),
  room_id uuid references catcul.rooms(id) on delete set null,
  expires_at timestamptz not null default (now() + interval '3 hours'),
  created_at timestamptz not null default now()
);

create index if not exists idx_arcade_lobbies_expires on catcul.arcade_lobbies (expires_at desc);
alter table catcul.arcade_lobbies enable row level security;
drop policy if exists arcade_lobbies_select on catcul.arcade_lobbies;
create policy arcade_lobbies_select on catcul.arcade_lobbies
  for select to authenticated using (expires_at > now());

grant select on catcul.arcade_games, catcul.arcade_lobbies to authenticated;

notify pgrst, 'reload schema';
commit;

select 'Catcul monetization & tiers ready: Catcul+, Catcul++, Catcul Premium, Admin automatic Premium, Stories, Spotlight, Video posts, and tiered Themes & Stickers.' as result;
