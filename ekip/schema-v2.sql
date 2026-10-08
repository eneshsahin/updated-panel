-- Updated Ekip Paneli: sema v2 (gun notu, is devri, etkinlik takvimi)

alter table public.availability add column if not exists note text not null default '' check (char_length(note) <= 120);
alter table public.jobs add column if not exists transfer_to uuid references public.profiles on delete set null;

create table if not exists public.events (
  id bigint generated always as identity primary key,
  title text not null,
  brand text not null default '',
  start_day date not null,
  end_day date,
  certainty text not null default 'kesin' check (certainty in ('kesin','tahmini')),
  note text not null default '',
  created_at timestamptz not null default now()
);
alter table public.events enable row level security;
create policy events_read on public.events for select to authenticated using (is_member());
create policy events_admin_ins on public.events for insert to authenticated with check (is_admin());
create policy events_admin_upd on public.events for update to authenticated using (is_admin()) with check (is_admin());
create policy events_admin_del on public.events for delete to authenticated using (is_admin());
grant select, insert, update, delete on public.events to authenticated;
revoke all on public.events from anon;
alter publication supabase_realtime add table public.events;

create or replace function public.assign_job(p_job bigint, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare j jobs; who text;
begin
  if not is_admin() then raise exception 'Sadece yonetici atama yapabilir'; end if;
  update jobs set status = 'atandi', assignee = p_user, transfer_to = null
  where id = p_job and status = 'havuz' returning * into j;
  if not found then raise exception 'Is bekleyenlerde degil'; end if;
  select name into who from profiles where id = p_user;
  if p_user is distinct from auth.uid() then
    insert into notifications (user_id, body)
    values (p_user, 'Talebin onaylandı: "' || j.brand || ' ' || j.title || '" artık sende.');
  end if;
  insert into notifications (user_id, body)
  select id, who || ', "' || j.brand || ' ' || j.title || '" işini üstlendi.'
  from profiles where id <> p_user and id is distinct from auth.uid();
end;
$$;

create or replace function public.offer_transfer(p_job bigint, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare j jobs; me_name text;
begin
  select * into j from jobs where id = p_job and status = 'atandi';
  if not found or not (j.assignee = auth.uid() or is_admin()) then
    raise exception 'Bu isi devretme yetkin yok';
  end if;
  if p_user is null then
    update jobs set transfer_to = null where id = p_job;
    return;
  end if;
  if p_user = j.assignee then raise exception 'Is zaten bu kiside'; end if;
  update jobs set transfer_to = p_user where id = p_job;
  select name into me_name from profiles where id = auth.uid();
  insert into notifications (user_id, body)
  values (p_user, me_name || ', "' || j.brand || ' ' || j.title || '" işini sana devretmek istiyor. İşler > Atananlar bölümünden yanıtla.');
end;
$$;

create or replace function public.answer_transfer(p_job bigint, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare j jobs; old_name text; new_name text;
begin
  select * into j from jobs where id = p_job and status = 'atandi' and transfer_to = auth.uid();
  if not found then raise exception 'Sana yapilmis bir devir teklifi yok'; end if;
  select name into old_name from profiles where id = j.assignee;
  select name into new_name from profiles where id = auth.uid();
  if p_accept then
    update jobs set assignee = auth.uid(), transfer_to = null where id = p_job;
    perform notify_all('"' || j.brand || ' ' || j.title || '" işi devredildi: ' || coalesce(old_name, '?') || ' → ' || new_name, auth.uid());
  else
    update jobs set transfer_to = null where id = p_job;
    if j.assignee is not null then
      insert into notifications (user_id, body)
      values (j.assignee, new_name || ', "' || j.brand || ' ' || j.title || '" işinin devrini kabul etmedi.');
    end if;
  end if;
end;
$$;

create or replace function public.auto_events() returns void
language plpgsql security definer set search_path = public as $$
declare today date := (now() at time zone 'Europe/Istanbul')::date;
begin
  insert into notifications (user_id, body)
  select p.id,
    'Yaklaşan: ' || case when e.brand <> '' then e.brand || ' · ' else '' end || e.title
    || ' · ' || to_char(e.start_day, 'DD.MM.YYYY')
    || case when e.certainty = 'tahmini' then ' (tahmini)' else '' end
    || case when e.start_day - today = 1 then ' · yarın' else ' · 1 hafta kaldı' end
  from events e cross join profiles p
  where e.start_day - today in (1, 7);
end;
$$;

revoke execute on function public.auto_events() from public, anon, authenticated;
revoke execute on function public.offer_transfer(bigint, uuid) from public, anon;
revoke execute on function public.answer_transfer(bigint, boolean) from public, anon;
grant execute on function public.offer_transfer(bigint, uuid) to authenticated;
grant execute on function public.answer_transfer(bigint, boolean) to authenticated;

select cron.schedule('etkinlik-hatirlatma', '5 6 * * *', 'select public.auto_events()');
select 'v2 tamam' as sonuc;
