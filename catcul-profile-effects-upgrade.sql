-- Historical reference only: this migration has ALREADY been applied to the connected Catcul project.
-- Do not rerun blindly. A public bucket makes uploaded effect GIFs accessible to anyone with their URL.
-- Each account can write only its own three fixed slots; the bucket limits files to 2 MiB and image/gif.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('catcul-profile-effects','catcul-profile-effects',true,2097152,ARRAY['image/gif'])
on conflict (id) do nothing;
create policy "profile_effects_read_own" on storage.objects for select to authenticated using (bucket_id='catcul-profile-effects' and name ~ ('^' || auth.uid()::text || '/effect[0-2]\.gif$'));
create policy "profile_effects_insert_own" on storage.objects for insert to authenticated with check (bucket_id='catcul-profile-effects' and name ~ ('^' || auth.uid()::text || '/effect[0-2]\.gif$'));
create policy "profile_effects_update_own" on storage.objects for update to authenticated using (bucket_id='catcul-profile-effects' and name ~ ('^' || auth.uid()::text || '/effect[0-2]\.gif$')) with check (bucket_id='catcul-profile-effects' and name ~ ('^' || auth.uid()::text || '/effect[0-2]\.gif$'));
create policy "profile_effects_delete_own" on storage.objects for delete to authenticated using (bucket_id='catcul-profile-effects' and name ~ ('^' || auth.uid()::text || '/effect[0-2]\.gif$'));
