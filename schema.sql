-- Split Pay: run this once in Supabase -> SQL Editor -> New query -> Run.

create table if not exists shops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references auth.users(id) on delete cascade,
  slug text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 10),
  name text not null check (char_length(name) between 1 and 80),
  upi_id text not null check (upi_id ~ '^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$'),
  merchant_code text check (merchant_code is null or merchant_code ~ '^[0-9]{4}$'),
  max_payment int not null default 2000 check (max_payment between 100 and 2000),
  created_at timestamptz not null default now()
);

create table if not exists bills (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references shops(id) on delete cascade,
  token text not null default substr(md5(random()::text || clock_timestamp()::text), 1, 16),
  total_paise int not null check (total_paise > 0 and total_paise <= 10000000),
  parts int not null check (parts between 1 and 50),
  status text not null default 'paying' check (status in ('paying', 'claimed', 'received')),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  received_at timestamptz
);
create index if not exists bills_shop_created on bills (shop_id, created_at desc);

alter table shops enable row level security;
alter table bills enable row level security;

-- Shop owners can see and edit only their own shop.
drop policy if exists shops_owner_all on shops;
create policy shops_owner_all on shops for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Shop owners can read (not directly edit) bills of their own shop.
drop policy if exists bills_owner_select on bills;
create policy bills_owner_select on bills for select
  using (exists (select 1 from shops s where s.id = bills.shop_id and s.owner_id = auth.uid()));

-- ---- Functions the customer page calls (no login needed) ----

create or replace function get_shop(p_slug text)
returns table (name text, upi_id text, merchant_code text, max_payment int)
language sql security definer set search_path = public as $$
  select name, upi_id, merchant_code, max_payment from shops where slug = p_slug
$$;

create or replace function start_bill(p_slug text, p_total int, p_parts int)
returns table (id uuid, token text)
language plpgsql security definer set search_path = public as $$
declare s uuid;
begin
  select shops.id into s from shops where slug = p_slug;
  if s is null then raise exception 'unknown shop'; end if;
  return query
    insert into bills (shop_id, total_paise, parts) values (s, p_total, p_parts)
    returning bills.id, bills.token;
end $$;

create or replace function claim_bill(p_id uuid, p_token text)
returns void
language sql security definer set search_path = public as $$
  update bills set status = 'claimed', claimed_at = now()
  where id = p_id and token = p_token and status = 'paying'
$$;

create or replace function bill_status(p_id uuid, p_token text)
returns text
language sql security definer set search_path = public as $$
  select status from bills where id = p_id and token = p_token
$$;

-- ---- Function only a logged-in shop owner can call ----

create or replace function mark_received(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update bills set status = 'received', received_at = now()
  where id = p_id and status = 'claimed'
    and shop_id in (select id from shops where owner_id = auth.uid());
end $$;

revoke execute on function mark_received(uuid) from public, anon;
grant execute on function mark_received(uuid) to authenticated;
grant execute on function get_shop(text), start_bill(text, int, int), claim_bill(uuid, text), bill_status(uuid, text) to anon, authenticated;

-- Live updates on the shop dashboard.
alter publication supabase_realtime add table bills;
