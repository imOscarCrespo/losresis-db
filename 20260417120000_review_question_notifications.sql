begin;

insert into public.notification_types (code, description)
values
  (
    'review_question_for_review_owner',
    'Notificacion cuando otro usuario hace una pregunta sobre la resena del residente'
  ),
  (
    'review_question_answer_for_asker',
    'Notificacion cuando un residente responde a una pregunta sobre su resena'
  )
on conflict (code) do nothing;

create or replace function public.notify_review_question_for_review_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.notifications (
    user_id,
    type,
    actor_user_id,
    title,
    body,
    entity_type,
    entity_id,
    data
  )
  select distinct on (r.user_id)
    r.user_id,
    'review_question_for_review_owner',
    new.user_id,
    'Nueva pregunta en tu resena',
    case
      when char_length(new.question_text) > 140 then left(new.question_text, 137) || '...'
      else new.question_text
    end,
    'review_question',
    new.id,
    jsonb_build_object(
      'entity_type', 'review_question',
      'entity_id', new.id,
      'question_id', new.id,
      'review_id', r.id,
      'destination_section', 'myReview',
      'focus', 'questions'
    )
  from public.review r
  join public.users u
    on u.id = r.user_id
  left join public.user_notification_preferences pref
    on pref.user_id = u.id
   and pref.notification_type = 'review_question_for_review_owner'
  where r.hospital_id = new.hospital_id
    and r.speciality_id = new.speciality_id
    and r.user_id <> new.user_id
    and (
      pref.user_id is null
      or coalesce(pref.push_enabled, true) = true
      or coalesce(pref.in_app_enabled, true) = true
    )
  order by
    r.user_id,
    (r.approved_at is not null) desc,
    r.approved_at desc nulls last,
    r.created_at desc;

  return new;
end;
$$;

create or replace function public.notify_review_question_answer_for_asker()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_question_user_id uuid;
  v_question_id uuid;
  v_review_id uuid;
begin
  select
    q.user_id,
    q.id
  into
    v_question_user_id,
    v_question_id
  from public.review_question q
  where q.id = new.question_id;

  if v_question_user_id is null or v_question_id is null then
    return new;
  end if;

  if v_question_user_id = new.user_id then
    return new;
  end if;

  select r.id
  into v_review_id
  from public.review_question q
  join public.review r
    on r.hospital_id = q.hospital_id
   and r.speciality_id = q.speciality_id
   and r.user_id = new.user_id
  where q.id = new.question_id
  order by
    (r.approved_at is not null) desc,
    r.approved_at desc nulls last,
    r.created_at desc
  limit 1;

  if v_review_id is null then
    return new;
  end if;

  insert into public.notifications (
    user_id,
    type,
    actor_user_id,
    title,
    body,
    entity_type,
    entity_id,
    data
  )
  select
    v_question_user_id,
    'review_question_answer_for_asker',
    new.user_id,
    'Han respondido a tu pregunta',
    case
      when char_length(new.answer_text) > 140 then left(new.answer_text, 137) || '...'
      else new.answer_text
    end,
    'review',
    v_review_id,
    jsonb_build_object(
      'entity_type', 'review',
      'entity_id', v_review_id,
      'review_id', v_review_id,
      'question_id', v_question_id,
      'destination_section', 'reviewDetail'
    )
  from public.users u
  left join public.user_notification_preferences pref
    on pref.user_id = u.id
   and pref.notification_type = 'review_question_answer_for_asker'
  where u.id = v_question_user_id
    and (
      pref.user_id is null
      or coalesce(pref.push_enabled, true) = true
      or coalesce(pref.in_app_enabled, true) = true
    );

  return new;
end;
$$;

drop trigger if exists trg_notify_review_question_for_review_owner
  on public.review_question;

create trigger trg_notify_review_question_for_review_owner
after insert on public.review_question
for each row
execute function public.notify_review_question_for_review_owner();

drop trigger if exists trg_notify_review_question_answer_for_asker
  on public.review_question_answer;

create trigger trg_notify_review_question_answer_for_asker
after insert on public.review_question_answer
for each row
execute function public.notify_review_question_answer_for_asker();

grant all on function public.notify_review_question_for_review_owner() to anon;
grant all on function public.notify_review_question_for_review_owner() to authenticated;
grant all on function public.notify_review_question_for_review_owner() to service_role;

grant all on function public.notify_review_question_answer_for_asker() to anon;
grant all on function public.notify_review_question_answer_for_asker() to authenticated;
grant all on function public.notify_review_question_answer_for_asker() to service_role;

commit;
