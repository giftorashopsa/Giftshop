-- Dear You Gifting SA : Supabase setup
-- Supabase > SQL Editor-e puro file paste kore Run korun (ek bar)

create extension if not exists pgcrypto;

-- ============ TABLES ============
create table if not exists staff(
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('staff','manager','owner'))
);

create table if not exists products(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  name_bn text, name_en text,
  price int not null, old_price int, cost int,
  icon text default '🎁', cat text, image_url text,
  active boolean default true,
  colors jsonb, prices jsonb, combo_items jsonb
);

create table if not exists orders(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  user_id uuid default auth.uid(),
  status text default 'new',
  name text, phone text, address text,
  total int, zone text, delivery_charge int,
  advance int, due int,
  bkash_number text, trx_id text unique, trx2 text,
  items jsonb,
  rname text, rphone text, city text, country text,
  bd_div text, bd_dist text,
  note text, ddate date, size text,
  gift boolean default false, cake boolean default false, cake_note text,
  custom_url text, stock_done boolean default false
);

create table if not exists settings(key text primary key, value jsonb);

create table if not exists expenses(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  who text, cat text, amount numeric, cur text default 'SAR',
  edate date default current_date, note text
);

create table if not exists purchases(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz default now(),
  kind text, item text, qty int, sar numeric, bdt int, img text, note text
);

-- ============ HELPER FUNCTIONS ============
create or replace function givora_role() returns text
language sql stable security definer set search_path=public as
$$ select role from staff where user_id=auth.uid() $$;

create or replace function givora_is_owner() returns boolean
language sql stable security definer set search_path=public as
$$ select coalesce(givora_role()='owner',false) $$;

create or replace function givora_is_manager() returns boolean
language sql stable security definer set search_path=public as
$$ select coalesce(givora_role() in ('manager','owner'),false) $$;

create or replace function givora_is_staff() returns boolean
language sql stable security definer set search_path=public as
$$ select givora_role() is not null $$;

-- ============ RPC (app e ja call kora hoy) ============
create or replace function list_staff() returns table(email text, role text)
language plpgsql security definer set search_path=public as $$
begin
  if not givora_is_owner() then raise exception 'not allowed'; end if;
  return query select u.email::text, s.role from staff s join auth.users u on u.id=s.user_id order by u.email;
end $$;

create or replace function add_staff(p_email text, p_role text) returns void
language plpgsql security definer set search_path=public as $$
declare uid uuid;
begin
  if not givora_is_owner() then raise exception 'not allowed'; end if;
  if p_role not in ('staff','manager','owner') then raise exception 'bad role'; end if;
  select id into uid from auth.users where lower(email)=lower(trim(p_email));
  if uid is null then raise exception 'User paoa jayni. Age sign-up korte bolun'; end if;
  insert into staff(user_id,role) values(uid,p_role)
  on conflict (user_id) do update set role=excluded.role;
end $$;

create or replace function remove_staff(p_email text) returns void
language plpgsql security definer set search_path=public as $$
begin
  if not givora_is_owner() then raise exception 'not allowed'; end if;
  delete from staff where user_id=(select id from auth.users where lower(email)=lower(trim(p_email)))
    and user_id<>auth.uid();
end $$;

create or replace function pay_second(p_id uuid, p_trx text) returns void
language plpgsql security definer set search_path=public as $$
begin
  update orders set trx2=upper(trim(p_trx))
  where id=p_id and user_id=auth.uid() and status='delivered' and trx2 is null;
  if not found then raise exception 'Order paoa jayni ba ager e payment hoye geche'; end if;
end $$;

-- ============ ROW LEVEL SECURITY ============
alter table staff enable row level security;
alter table products enable row level security;
alter table orders enable row level security;
alter table settings enable row level security;
alter table expenses enable row level security;
alter table purchases enable row level security;

-- staff: nijer row dekhte pare
drop policy if exists staff_self on staff;
create policy staff_self on staff for select to authenticated using (user_id=auth.uid());

-- products: sobai dekhe, manager/owner likhe
drop policy if exists prod_read on products;
drop policy if exists prod_write on products;
create policy prod_read on products for select to anon, authenticated using (true);
create policy prod_write on products for all to authenticated
  using (givora_is_manager()) with check (givora_is_manager());

-- orders
drop policy if exists ord_insert on orders;
drop policy if exists ord_select on orders;
drop policy if exists ord_update on orders;
drop policy if exists owner_delete_orders on orders;
create policy ord_insert on orders for insert to anon, authenticated
  with check (status='new' and trx2 is null and coalesce(stock_done,false)=false);
create policy ord_select on orders for select to authenticated
  using (givora_is_staff() or user_id=auth.uid());
create policy ord_update on orders for update to authenticated
  using (givora_is_staff()) with check (givora_is_staff());
create policy owner_delete_orders on orders for delete to authenticated using (givora_is_owner());

-- settings: sobai pore (delivery charge), owner likhe
drop policy if exists set_read on settings;
drop policy if exists set_write on settings;
create policy set_read on settings for select to anon, authenticated using (true);
create policy set_write on settings for all to authenticated
  using (givora_is_owner()) with check (givora_is_owner());

-- expenses & purchases: shudhu owner
drop policy if exists exp_all on expenses;
create policy exp_all on expenses for all to authenticated
  using (givora_is_owner()) with check (givora_is_owner());
drop policy if exists pur_all on purchases;
create policy pur_all on purchases for all to authenticated
  using (givora_is_owner()) with check (givora_is_owner());

-- ============ STORAGE (ছবি) ============
insert into storage.buckets(id,name,public) values('products','products',true)
on conflict (id) do update set public=true;

drop policy if exists "products read" on storage.objects;
drop policy if exists "products upload" on storage.objects;
create policy "products read" on storage.objects for select to anon, authenticated
  using (bucket_id='products');
create policy "products upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id='products');

-- ============ PROTHOM OWNER ============
-- 1) App e Sign-up kore nin (nijer Gmail diye)
-- 2) Tarpor nicher line e email bodle Run korun:
--
-- insert into staff(user_id,role)
-- select id,'owner' from auth.users where email='YOUR_EMAIL@gmail.com'
-- on conflict (user_id) do update set role='owner';
