-- Energy Saver Hub: Free Site Visit funnel (Supabase project axjbalzirbdhfuutmmuw)
--
-- 1. leads table + private `bills` bucket. The browser (publishable key) can
--    only INSERT. Nobody can read leads or bills without the secret key.
-- 2. Every new lead is forwarded to QuoteLeadsHQ (The Pirotta Group's account)
--    through ql-hq's `esh-intake` function, bill included.
-- 3. Every new lead is also POSTed to Energy Saver Hub's Make.com webhook.
--
-- Both forwards are asynchronous (pg_net) and can never block the website's
-- insert. Safe to run more than once.
--
-- BEFORE leads can reach QuoteLeadsHQ, store the shared intake secret (the
-- same value as ESH_INTAKE_SECRET in ql-hq's edge function secrets) once:
--   select vault.create_secret('<the secret>', 'qlhq_intake_secret');

create extension if not exists pg_net;

-- ---------- LEADS TABLE ----------
create table if not exists public.leads (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  interest        text not null check (interest in ('Solar','Battery','Solar + Battery','Not sure')),
  existing_solar  text not null check (existing_solar in ('No, nothing yet','Yes, panels only','Yes, panels + battery')),
  solar_age       text check (solar_age in ('Under 5 years','5 to 10 years','10 to 15 years','Over 15 years','Not sure')),
  feed_in_tariff  text check (char_length(feed_in_tariff) <= 80),
  has_battery     text check (has_battery in ('Yes','No')),
  bill_range      text not null check (bill_range in ('Under $300','$300 to $600','$600 to $1,000','Over $1,000')),
  ownership       text not null check (ownership in ('Own outright','Mortgaged')),
  timeframe       text not null check (timeframe in ('ASAP','1 to 3 months','3 to 6 months','Researching')),
  name            text not null check (char_length(name) between 1 and 120),
  email           text not null check (char_length(email) <= 200 and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone           text not null check (char_length(phone) between 8 and 30),
  suburb          text check (char_length(suburb) between 1 and 80),
  postcode        text not null check (postcode ~ '^\d{4}$'),
  bill_path       text check (char_length(bill_path) <= 300),
  bill_filename   text check (char_length(bill_filename) <= 200),
  source          text check (char_length(source) <= 100),
  tracking        jsonb not null default '{}'::jsonb check (pg_column_size(tracking) < 4000),
  -- written by the forwards, never by the website
  qlhq_lead_id    uuid,
  qlhq_synced_at  timestamptz,
  make_request_id bigint
);

create index if not exists leads_created_at_idx on public.leads (created_at desc);

alter table public.leads enable row level security;

-- Browser may insert new leads only. No select/update/delete policies exist,
-- so anon cannot read anything back. The column grant stops it writing the
-- sync columns.
drop policy if exists "anon can insert leads" on public.leads;
create policy "anon can insert leads"
  on public.leads for insert
  to anon
  with check (true);

revoke all on public.leads from anon, authenticated;
grant insert (interest, existing_solar, solar_age, feed_in_tariff, has_battery,
              bill_range, ownership, timeframe, name, email, phone, suburb, postcode,
              bill_path, bill_filename, source, tracking)
  on public.leads to anon;

-- ---------- PRIVATE BILL STORAGE ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('bills', 'bills', false, 10485760, array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Browser may upload into the bills bucket only. No read, list, overwrite or delete.
drop policy if exists "anon can upload bills" on storage.objects;
create policy "anon can upload bills"
  on storage.objects for insert
  to anon
  with check (bucket_id = 'bills');

-- ---------- LEAD INBOX VIEW (Table Editor > Views > lead_inbox) ----------
create or replace view public.lead_inbox
with (security_invoker = true) as
select
  to_char(created_at at time zone 'Australia/Melbourne', 'DD Mon YYYY HH12:MI am') as received,
  name,
  phone,
  email,
  suburb,
  postcode,
  case when bill_path is not null then 'Yes' else 'No' end as bill_uploaded,
  bill_path  as bill_in_storage,   -- Storage > bills > this path
  interest,
  existing_solar,
  solar_age,
  feed_in_tariff,
  has_battery,
  bill_range,
  ownership,
  timeframe,
  tracking->>'utm_campaign' as campaign,
  case when qlhq_synced_at is not null then 'Yes' else 'No' end as in_quoteleadshq,
  id
from public.leads
order by created_at desc;

revoke all on public.lead_inbox from anon, authenticated;

-- ---------- FORWARD TO QUOTELEADSHQ (The Pirotta Group) ----------
create or replace function public.send_lead_to_qlhq(lead public.leads)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  secret text;
begin
  select decrypted_secret into secret
  from vault.decrypted_secrets
  where name = 'qlhq_intake_secret'
  limit 1;

  if secret is null then
    raise warning 'qlhq_intake_secret is not in Vault; lead % not sent to ql-hq', lead.id;
    return;
  end if;

  perform net.http_post(
    url     := 'https://wjadekgptkstfdootuol.supabase.co/functions/v1/esh-intake',
    body    := to_jsonb(lead),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-intake-secret', secret
    ),
    timeout_milliseconds := 30000
  );
end;
$$;

-- Re-send every lead ql-hq hasn't confirmed (safe to run repeatedly: ql-hq
-- skips leads it already has and only retries a missing bill).
--   select public.forward_leads_to_qlhq();
create or replace function public.forward_leads_to_qlhq()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.leads;
  n integer := 0;
begin
  for r in select * from public.leads where qlhq_synced_at is null order by created_at loop
    perform public.send_lead_to_qlhq(r);
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- ---------- FORWARD TO MAKE.COM ----------
-- Flat, readable payload for the Make scenario. The bill itself stays in
-- private storage (and is attached to the lead in QuoteLeadsHQ).
create or replace function public.send_lead_to_make(lead public.leads)
returns bigint
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  first_name text := split_part(lead.name, ' ', 1);
  req_id bigint;
begin
  select net.http_post(
    url     := 'https://hook.eu2.make.com/4pgya7ebu2iqx7nihqhp1ftya9z65xag',
    body    := jsonb_build_object(
      'lead_id',        lead.id,
      'submitted_at',   lead.created_at,
      'submitted_at_melbourne', to_char(lead.created_at at time zone 'Australia/Melbourne', 'DD Mon YYYY HH12:MI am'),
      'business',       'Energy Saver Hub',
      'name',           lead.name,
      'first_name',     first_name,
      'last_name',      nullif(trim(substr(lead.name, char_length(first_name) + 1)), ''),
      'email',          lead.email,
      'phone',          lead.phone,
      'suburb',         lead.suburb,
      'postcode',       lead.postcode,
      'state',          'VIC',
      'interest',       lead.interest,
      'existing_solar', lead.existing_solar,
      'solar_age',      lead.solar_age,
      'feed_in_tariff', lead.feed_in_tariff,
      'has_battery',    lead.has_battery,
      'bill_range',     lead.bill_range,
      'ownership',      lead.ownership,
      'timeframe',      lead.timeframe,
      'bill_uploaded',  case when lead.bill_path is not null then 'Yes' else 'No' end,
      'bill_filename',  lead.bill_filename,
      'source',         lead.source,
      'utm_source',     lead.tracking->>'utm_source',
      'utm_medium',     lead.tracking->>'utm_medium',
      'utm_campaign',   lead.tracking->>'utm_campaign',
      'utm_content',    lead.tracking->>'utm_content',
      'utm_term',       lead.tracking->>'utm_term',
      'fbclid',         lead.tracking->>'fbclid',
      'page',           lead.tracking->>'page'
    ),
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 30000
  ) into req_id;
  return req_id;
end;
$$;

-- ---------- TRIGGER: both forwards on every new lead ----------
-- (BEFORE insert so the Make request id is stored on the row itself.)
drop trigger if exists leads_forward_to_qlhq on public.leads;
drop function if exists public.leads_forward_to_qlhq();

create or replace function public.leads_forward()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Never let a forward break the website's insert.
  begin
    new.make_request_id := public.send_lead_to_make(new);
  exception when others then
    raise warning 'forward to Make failed for lead %: %', new.id, sqlerrm;
  end;
  begin
    perform public.send_lead_to_qlhq(new);
  exception when others then
    raise warning 'forward to ql-hq failed for lead %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists leads_forward on public.leads;
create trigger leads_forward
  before insert on public.leads
  for each row execute function public.leads_forward();

-- These run as the table owner; keep them away from the website's roles.
revoke all on function public.send_lead_to_qlhq(public.leads) from public, anon, authenticated;
revoke all on function public.forward_leads_to_qlhq()         from public, anon, authenticated;
revoke all on function public.send_lead_to_make(public.leads) from public, anon, authenticated;
revoke all on function public.leads_forward()                 from public, anon, authenticated;
