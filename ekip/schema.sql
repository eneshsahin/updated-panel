-- Updated Ekip Paneli: veritabani semasi (v1)

create table public.invites (
  email text primary key,
  name text not null,
  role text not null default '',
  org text not null default '',
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  email text not null,
  name text not null,
  role text not null default '',
  org text not null default '',
  is_admin boolean not null default false,
  notify_email boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.availability (
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  day date not null,
  status text not null check (status in ('bos','dolu')),
  slot text not null default '',
  loc text not null default 'İstanbul',
  primary key (user_id, day)
);

create table public.week_notes (
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  week_start date not null,
  note text not null default '' check (char_length(note) <= 120),
  primary key (user_id, week_start)
);

create table public.jobs (
  id bigint generated always as identity primary key,
  brand text not null,
  category text not null default 'kamera',
  type text not null,
  title text not null,
  due date not null,
  embargo date,
  status text not null default 'havuz' check (status in ('havuz','atandi','bitti')),
  assignee uuid references public.profiles on delete set null,
  created_by uuid default auth.uid() references public.profiles on delete set null,
  created_at timestamptz not null default now(),
  done_at timestamptz
);

create table public.job_requests (
  job_id bigint not null references public.jobs on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles on delete cascade,
  created_at timestamptz not null default now(),
  primary key (job_id, user_id)
);

create table public.gear (
  id bigint generated always as identity primary key,
  name text not null,
  category text not null default 'kamera',
  status text not null default 'elimizde' check (status in ('elimizde','yolda')),
  holder uuid references public.profiles on delete set null,
  day date,
  created_at timestamptz not null default now()
);

create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles on delete cascade,
  body text not null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);

-- Yardimci fonksiyonlar
create function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid());
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;

create function public.notify_admins(p_body text, p_except uuid default null) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, body)
  select id, p_body from profiles where is_admin and id is distinct from p_except;
$$;

create function public.notify_all(p_body text, p_except uuid default null) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, body)
  select id, p_body from profiles where id is distinct from p_except;
$$;

-- Kayit: sadece davet listesindeki e-postalar uye olabilir
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invites;
begin
  select * into inv from invites where lower(email) = lower(new.email);
  if not found then
    raise exception 'Bu e-posta davet listesinde yok';
  end if;
  insert into profiles (id, email, name, role, org, is_admin)
  values (new.id, new.email, inv.name, inv.role, inv.org, inv.is_admin);
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Uye kendi yoneticilik yetkisini degistiremez
create function public.protect_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin()
     and (new.is_admin is distinct from old.is_admin or new.email is distinct from old.email) then
    raise exception 'Bu alani sadece yonetici degistirebilir';
  end if;
  return new;
end;
$$;
create trigger profiles_protect before update on public.profiles
  for each row execute function public.protect_profile();

-- Bildirim tetikleyicileri
create function public.on_job_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform notify_all('Havuza yeni iş eklendi: ' || new.brand || ' ' || new.title, auth.uid());
  return new;
end;
$$;
create trigger jobs_created after insert on public.jobs
  for each row execute function public.on_job_created();

create function public.on_job_requested() returns trigger
language plpgsql security definer set search_path = public as $$
declare j jobs; who text;
begin
  select * into j from jobs where id = new.job_id;
  select name into who from profiles where id = new.user_id;
  perform notify_admins(who || ', "' || j.brand || ' ' || j.title || '" işini almak istiyor.', new.user_id);
  return new;
end;
$$;
create trigger job_requested after insert on public.job_requests
  for each row execute function public.on_job_requested();

-- Islemler
create function public.assign_job(p_job bigint, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare j jobs; who text;
begin
  if not is_admin() then raise exception 'Sadece yonetici atama yapabilir'; end if;
  update jobs set status = 'atandi', assignee = p_user where id = p_job and status = 'havuz' returning * into j;
  if not found then raise exception 'Is havuzda degil'; end if;
  select name into who from profiles where id = p_user;
  insert into notifications (user_id, body)
  values (p_user, 'Talebin onaylandı: "' || j.brand || ' ' || j.title || '" artık sende.');
  insert into notifications (user_id, body)
  select user_id, '"' || j.brand || ' ' || j.title || '" işi ' || who || ' adlı üyeye verildi.'
  from job_requests where job_id = p_job and user_id <> p_user;
end;
$$;

create function public.complete_job(p_job bigint) returns void
language plpgsql security definer set search_path = public as $$
declare j jobs; who text;
begin
  update jobs set status = 'bitti', done_at = now()
  where id = p_job and status = 'atandi' and (assignee = auth.uid() or is_admin())
  returning * into j;
  if not found then raise exception 'Bu isi tamamlama yetkin yok'; end if;
  select name into who from profiles where id = j.assignee;
  perform notify_all(coalesce(who, 'Ekip') || ', "' || j.brand || ' ' || j.title || '" işini tamamladı.', auth.uid());
end;
$$;

create function public.send_reminder() returns integer
language plpgsql security definer set search_path = public as $$
declare ws date := date_trunc('week', (now() at time zone 'Europe/Istanbul'))::date; n integer;
begin
  if not is_admin() then raise exception 'Sadece yonetici hatirlatma gonderebilir'; end if;
  insert into notifications (user_id, body)
  select p.id, 'Bu hafta müsaitliğini henüz işaretlemedin.'
  from profiles p
  where not exists (select 1 from availability a where a.user_id = p.id and a.day >= ws and a.day < ws + 7);
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Satir guvenligi
alter table public.invites enable row level security;
alter table public.profiles enable row level security;
alter table public.availability enable row level security;
alter table public.week_notes enable row level security;
alter table public.jobs enable row level security;
alter table public.job_requests enable row level security;
alter table public.gear enable row level security;
alter table public.notifications enable row level security;

create policy invites_admin on public.invites for all to authenticated using (is_admin()) with check (is_admin());

create policy profiles_read on public.profiles for select to authenticated using (is_member());
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());
create policy profiles_delete on public.profiles for delete to authenticated using (is_admin());

create policy avail_read on public.availability for select to authenticated using (is_member());
create policy avail_ins on public.availability for insert to authenticated with check (user_id = auth.uid() and is_member());
create policy avail_upd on public.availability for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy avail_del on public.availability for delete to authenticated using (user_id = auth.uid());

create policy notes_read on public.week_notes for select to authenticated using (is_member());
create policy notes_ins on public.week_notes for insert to authenticated with check (user_id = auth.uid() and is_member());
create policy notes_upd on public.week_notes for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy jobs_read on public.jobs for select to authenticated using (is_member());
create policy jobs_admin_ins on public.jobs for insert to authenticated with check (is_admin());
create policy jobs_admin_upd on public.jobs for update to authenticated using (is_admin()) with check (is_admin());
create policy jobs_admin_del on public.jobs for delete to authenticated using (is_admin());

create policy req_read on public.job_requests for select to authenticated using (is_member());
create policy req_ins on public.job_requests for insert to authenticated
  with check (user_id = auth.uid() and is_member()
    and exists (select 1 from public.jobs j where j.id = job_id and j.status = 'havuz'));
create policy req_del on public.job_requests for delete to authenticated using (user_id = auth.uid() or is_admin());

create policy gear_read on public.gear for select to authenticated using (is_member());
create policy gear_admin_ins on public.gear for insert to authenticated with check (is_admin());
create policy gear_admin_upd on public.gear for update to authenticated using (is_admin()) with check (is_admin());
create policy gear_admin_del on public.gear for delete to authenticated using (is_admin());

create policy notif_read on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notif_upd on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notif_del on public.notifications for delete to authenticated using (user_id = auth.uid());

-- Yetkiler
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on function public.notify_admins(text, uuid) from public, anon, authenticated;
revoke execute on function public.notify_all(text, uuid) from public, anon, authenticated;
revoke execute on function public.assign_job(bigint, uuid) from public, anon;
revoke execute on function public.complete_job(bigint) from public, anon;
revoke execute on function public.send_reminder() from public, anon;
grant execute on function public.assign_job(bigint, uuid) to authenticated;
grant execute on function public.complete_job(bigint) to authenticated;
grant execute on function public.send_reminder() to authenticated;

-- Anlik yenileme
alter publication supabase_realtime add table public.availability, public.week_notes, public.jobs,
  public.job_requests, public.gear, public.notifications, public.profiles;

select 'kurulum tamam' as sonuc;
