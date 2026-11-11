-- Free core video calling and 24-hour Stories, without changing account or room access.
-- The migration updates existing function bodies only after checking the expected guards.
do $migration$
declare f text; original text;
begin
  select pg_get_functiondef('catcul.get_my_entitlements()'::regprocedure) into f;
  f := replace(f, E'\r', ''); original := f;
  f := replace(f, '''video_calls'', v_rank >= 1', '''video_calls'', true');
  f := replace(f, '''stories_post'', v_rank >= 3', '''stories_post'', true');
  if f = original or position('''video_calls'', true' in f) = 0 or position('''stories_post'', true' in f) = 0 then raise exception 'Unexpected entitlements function'; end if;
  execute f;

  select pg_get_functiondef('catcul.enable_call_video(uuid)'::regprocedure) into f;
  f := replace(f, E'\r', ''); original := f;
  f := replace(f, E'  if not catcul.has_tier(''plus'', auth.uid()) then\n    raise exception ''Video calls require Catcul+.'' using errcode = ''42501'';\n  end if;\n', '');
  if f = original or position('can_send_to_room' in f) = 0 then raise exception 'Unexpected video authorization function'; end if;
  execute f;

  select pg_get_functiondef('catcul.authorize_voice_join(uuid)'::regprocedure) into f;
  f := replace(f, E'\r', ''); original := f;
  f := replace(f, '''can_video'', catcul.has_tier(''plus'', v_uid)', '''can_video'', true');
  if f = original or position('call_participants' in f) = 0 then raise exception 'Unexpected call join authorization function'; end if;
  execute f;

  select pg_get_functiondef('catcul.can_upload_media(text)'::regprocedure) into f;
  f := replace(f, E'\r', ''); original := f;
  f := replace(f, 'if not catcul.has_tier(''premium'', v_uid) then', 'if v_head = ''spotlight'' and not catcul.has_tier(''premium'', v_uid) then');
  if f = original or position('account_is_active' in f) = 0 or position('can_send_to_room' in f) = 0 then raise exception 'Unexpected media authorization function'; end if;
  execute f;

  select pg_get_functiondef('catcul.create_story(text,text,text,integer,text,text,jsonb)'::regprocedure) into f;
  f := replace(f, E'\r', ''); original := f;
  f := replace(f, E'  if not catcul.has_tier(''premium'', v_uid) then\n    raise exception ''Posting Stories requires Catcul Premium.'' using errcode = ''42501'';\n  end if;\n', '');
  if f = original or position('consume_rate' in f) = 0 or position('assert_active_account' in f) = 0 then raise exception 'Unexpected story function'; end if;
  execute f;
end $migration$;

update catcul.billing_plans set tagline = case tier
 when 'plus' then 'Extra themes and stickers for your space.'
 when 'plusplus' then 'Illustrated camera filters and more themes and stickers.'
 when 'premium' then 'Culife posting, video posts, and the full theme gallery.'
 else tagline end, updated_at = now()
where tier in ('plus','plusplus','premium');
