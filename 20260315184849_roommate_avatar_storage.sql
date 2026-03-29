insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'roommate-avatar',
  'roommate-avatar',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "roommate avatar public read"
on storage.objects
for select
to public
using (bucket_id = 'roommate-avatar');

create policy "roommate avatar insert own"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'roommate-avatar'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy "roommate avatar update own"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'roommate-avatar'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'roommate-avatar'
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy "roommate avatar delete own"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'roommate-avatar'
  and (storage.foldername(name))[1] = auth.uid()::text
);
