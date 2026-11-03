-- Run PRIVATELY in Supabase SQL Editor after catcul-student-upgrade.sql.
-- Owner email supplied by the user; keep this script private.
-- This script does not create an account: register/sign in to Catcul first.
-- Do not put a password or an API key here.
do $$
declare account_email text := 'newgruman@outlook.com'; owner_id uuid;
begin
 if account_email='REPLACE_WITH_YOUR_CATCUL_ACCOUNT_EMAIL' or position('@' in account_email)=0 then
  raise exception 'Replace the email placeholder with your existing Catcul sign-in email first.';
 end if;
 select id into owner_id from auth.users where lower(email)=lower(btrim(account_email));
 if owner_id is null or not exists(select 1 from catcul.profiles where id=owner_id) then
  raise exception 'No matching Catcul profile. Register and sign in with that email first.';
 end if;
 if exists(select 1 from catcul.platform_admins where role='owner' and user_id<>owner_id) then
  raise exception 'An owner already exists. Review ownership privately instead of adding another owner accidentally.';
 end if;
 insert into catcul.platform_admins(user_id,role) values(owner_id,'owner')
 on conflict(user_id) do update set role='owner';
 raise notice 'Owner access granted. Refresh Catcul to open the admin panel.';
end $$;
