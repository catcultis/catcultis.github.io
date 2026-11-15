-- Catcul v42: self-service account deletion (applied to project qrepissmmytfhwyxzfgk on 2026-11-15)
-- Called from Settings -> "Delete account" via db.rpc('delete_my_account').
-- Only the signed-in user can delete their own account; anon/public cannot execute it.

create or replace function catcul.delete_my_account()
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not signed in';
  end if;

  -- Clear NO ACTION references to profiles (must happen before profile deletion)
  update catcul.rooms set created_by = null where created_by = v_uid;
  update catcul.room_invites set created_by = null where created_by = v_uid;
  delete from catcul.color_card_games where turn_id = v_uid or winner_id = v_uid or host_id = v_uid;
  delete from catcul.draw_games where winner_id = v_uid;
  delete from catcul.guest_sessions where claimed_by = v_uid;

  -- Delete the auth user (cascades to profiles and arcade_lobbies;
  -- CASCADE / SET NULL constraints handle remaining dependents)
  delete from auth.users where id = v_uid;
end;
$$;

revoke execute on function catcul.delete_my_account() from public, anon;
grant execute on function catcul.delete_my_account() to authenticated;
