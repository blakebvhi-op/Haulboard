-- ═══════════════════════════════════════════════════════════════════
-- HaulBoard — junk car pickup dispatch
-- Supabase schema + RLS. Run this whole file once in the SQL editor.
-- ═══════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ── Tables ─────────────────────────────────────────────────────────
create table if not exists public.companies (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  join_code   text not null unique,
  phone       text,
  created_at  timestamptz not null default now()
);

create table if not exists public.profiles (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  company_id   uuid not null references public.companies(id) on delete cascade,
  role         text not null check (role in ('owner','dispatcher','driver')),
  display_name text,
  phone        text,
  color        text,
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists profiles_company_idx on public.profiles(company_id);

-- One row per car. A pickup is one-off (unlike a recurring plow account),
-- so the arrival / loaded / paid timestamps live right on the row.
create table if not exists public.pickups (
  id             text primary key,                 -- client-generated 'pk_…'
  company_id     uuid not null references public.companies(id) on delete cascade,
  status         text not null default 'new'
                 check (status in ('new','scheduled','done','cancelled')),
  -- seller
  seller_name    text,
  seller_phone   text,
  address        text,
  source         text,                             -- call, text, facebook, craigslist, referral, other
  -- vehicle
  year           int,
  make           text,
  model          text,
  color          text,
  vin            text,
  plate          text,
  title_status   text default 'has_title'
                 check (title_status in ('has_title','no_title','lien','unknown')),
  runs           boolean,
  has_keys       boolean,
  has_wheels     boolean default true,
  has_cat        boolean,                          -- catalytic converter present
  condition      text,                             -- free text: "no engine", "rolled", etc.
  -- deal
  offer_price    numeric(10,2) default 0,          -- what we told the seller we'd pay
  notes          text,
  -- scheduling
  scheduled_date date,
  time_window    text,                             -- "morning", "1-3pm", etc.
  run_id         text,                             -- runs.id (nullable)
  driver_id      uuid,                             -- profiles.user_id
  -- field progress (set by the driver)
  arrived_at     timestamptz,
  loaded_at      timestamptz,
  paid_amount    numeric(10,2),
  paid_method    text,                             -- cash, check, zelle, venmo, other
  paid_at        timestamptz,
  paid_by        uuid,
  -- disposition (owner fills in after the fact)
  yard_name      text,
  yard_price     numeric(10,2),
  yard_paid_at   timestamptz,
  tow_fee        numeric(10,2),                    -- extra charged to seller (rare) or paid to sub
  -- bookkeeping
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists pickups_company_idx on public.pickups(company_id);
create index if not exists pickups_sched_idx   on public.pickups(company_id, scheduled_date);
create index if not exists pickups_run_idx     on public.pickups(run_id);

-- A run = one driver's ordered list of stops on one day.
create table if not exists public.runs (
  id          text primary key,                    -- client-generated 'run_…'
  company_id  uuid not null references public.companies(id) on delete cascade,
  run_date    date not null,
  driver_id   uuid,                                -- profiles.user_id (nullable = unassigned)
  status      text not null default 'queued' check (status in ('queued','active','done')),
  stop_ids    jsonb not null default '[]'::jsonb,  -- ordered pickups.id[]
  name        text,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists runs_company_date_idx on public.runs(company_id, run_date);

-- ── Helpers ─────────────────────────────────────────────────────────
create or replace function public.my_company_id() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.profiles where user_id = auth.uid()
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.profiles where user_id = auth.uid()
$$;

create or replace function public.is_manager() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('owner','dispatcher') from public.profiles where user_id = auth.uid()), false)
$$;

-- Random 6-char join code without ambiguous characters
create or replace function public.gen_join_code() returns text
language plpgsql as $$
declare chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; out text := ''; i int;
begin
  for i in 1..6 loop
    out := out || substr(chars, 1 + floor(random()*length(chars))::int, 1);
  end loop;
  return out;
end $$;

-- Sign-up path 1: create a company and become its owner.
create or replace function public.signup_create_company(p_company_name text, p_display_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cid uuid; code text;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','not_signed_in'); end if;
  if exists (select 1 from profiles where user_id = auth.uid()) then
    return jsonb_build_object('ok',false,'error','already_has_company');
  end if;
  loop
    code := gen_join_code();
    exit when not exists (select 1 from companies where join_code = code);
  end loop;
  insert into companies(name, join_code) values (p_company_name, code) returning id into cid;
  insert into profiles(user_id, company_id, role, display_name)
    values (auth.uid(), cid, 'owner', coalesce(p_display_name, split_part((select email from auth.users where id=auth.uid()),'@',1)));
  return jsonb_build_object('ok',true,'company_id',cid,'join_code',code);
end $$;

-- Sign-up path 2: join an existing company as a driver with its join code.
create or replace function public.join_company(p_code text, p_display_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','not_signed_in'); end if;
  if exists (select 1 from profiles where user_id = auth.uid()) then
    return jsonb_build_object('ok',false,'error','already_has_company');
  end if;
  select id into cid from companies where join_code = upper(trim(p_code));
  if cid is null then return jsonb_build_object('ok',false,'error','bad_code'); end if;
  insert into profiles(user_id, company_id, role, display_name)
    values (auth.uid(), cid, 'driver', coalesce(p_display_name, split_part((select email from auth.users where id=auth.uid()),'@',1)));
  return jsonb_build_object('ok',true,'company_id',cid);
end $$;

-- Owner can rotate the join code if it leaks.
create or replace function public.rotate_join_code()
returns text language plpgsql security definer set search_path = public as $$
declare code text;
begin
  if my_role() <> 'owner' then raise exception 'owner only'; end if;
  loop
    code := gen_join_code();
    exit when not exists (select 1 from companies where join_code = code);
  end loop;
  update companies set join_code = code where id = my_company_id();
  return code;
end $$;

-- ── RLS ─────────────────────────────────────────────────────────────
alter table public.companies enable row level security;
alter table public.profiles  enable row level security;
alter table public.pickups   enable row level security;
alter table public.runs      enable row level security;

-- companies: members read their own; owner edits name/phone
drop policy if exists companies_select on public.companies;
create policy companies_select on public.companies for select using (id = my_company_id());
drop policy if exists companies_update on public.companies;
create policy companies_update on public.companies for update using (id = my_company_id() and my_role()='owner');

-- profiles: everyone in the company can see the team; owner edits any; a user edits their own name/phone
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select using (company_id = my_company_id());
drop policy if exists profiles_update_owner on public.profiles;
create policy profiles_update_owner on public.profiles for update using (company_id = my_company_id() and my_role()='owner');
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update using (user_id = auth.uid());
drop policy if exists profiles_delete_owner on public.profiles;
create policy profiles_delete_owner on public.profiles for delete using (company_id = my_company_id() and my_role()='owner' and user_id <> auth.uid());

-- pickups: company-wide read; managers insert/delete; everyone in the company can update
-- (drivers need to stamp arrived/loaded/paid; keeping update open is simpler than column-level policies)
drop policy if exists pickups_select on public.pickups;
create policy pickups_select on public.pickups for select using (company_id = my_company_id());
drop policy if exists pickups_insert on public.pickups;
create policy pickups_insert on public.pickups for insert with check (company_id = my_company_id() and is_manager());
drop policy if exists pickups_update on public.pickups;
create policy pickups_update on public.pickups for update using (company_id = my_company_id()) with check (company_id = my_company_id());
drop policy if exists pickups_delete on public.pickups;
create policy pickups_delete on public.pickups for delete using (company_id = my_company_id() and is_manager());

-- runs: same shape
drop policy if exists runs_select on public.runs;
create policy runs_select on public.runs for select using (company_id = my_company_id());
drop policy if exists runs_insert on public.runs;
create policy runs_insert on public.runs for insert with check (company_id = my_company_id() and is_manager());
drop policy if exists runs_update on public.runs;
create policy runs_update on public.runs for update using (company_id = my_company_id()) with check (company_id = my_company_id());
drop policy if exists runs_delete on public.runs;
create policy runs_delete on public.runs for delete using (company_id = my_company_id() and is_manager());

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.companies, public.profiles, public.pickups, public.runs to authenticated;
grant execute on function public.signup_create_company(text,text), public.join_company(text,text), public.rotate_join_code(),
  public.my_company_id(), public.my_role(), public.is_manager() to authenticated;
