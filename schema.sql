-- Agenday: banco de dados central (Supabase / PostgreSQL)
-- Rode este arquivo inteiro no SQL Editor do Supabase. Pode ser rodado de novo sem perder dados.
--
-- Quem enxerga o quê:
--   * Visitante (sem login): vê o perfil público dos negócios aprovados e só os HORÁRIOS ocupados
--     (sem nomes); agenda pela função public_book.
--   * Profissional aprovado: lê e altera apenas o próprio negócio, seus clientes e agendamentos.
--   * Administrador: enxerga tudo e aprova ou bloqueia contas.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null default '',
  name text not null default '',
  status text not null default 'pending' check (status in ('pending', 'approved', 'blocked')),
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.shops (
  slug text primary key check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(slug) between 2 and 40),
  owner uuid not null references public.profiles (id) on delete cascade,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists shops_owner_idx on public.shops (owner);

create table if not exists public.clients (
  id text primary key check (char_length(id) between 3 and 64),
  shop text not null references public.shops (slug) on delete cascade,
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists clients_shop_idx on public.clients (shop);

create table if not exists public.bookings (
  id text primary key check (char_length(id) between 3 and 64),
  shop text not null references public.shops (slug) on delete cascade,
  date text not null check (date ~ '^\d{4}-\d{2}-\d{2}$'),
  start integer not null check (start between 0 and 1439),
  dur integer not null check (dur between 1 and 1440),
  status text not null default 'agendado' check (status in ('agendado', 'concluido', 'cancelado')),
  data jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists bookings_shop_date_idx on public.bookings (shop, date);

-- ---------- funções de apoio ----------
create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and status = 'approved');
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and status = 'approved' and is_admin);
$$;

create or replace function public.owns_shop(p_slug text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from shops s join profiles p on p.id = s.owner
    where s.slug = p_slug and s.owner = auth.uid() and p.status = 'approved');
$$;

create or replace function public.owner_approved(p_owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = p_owner and status = 'approved');
$$;

create or replace function public.bare_phone(p text) returns text
language sql immutable as $$
  select case when char_length(d) > 11 and left(d, 2) = '55' then substr(d, 3) else d end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) t;
$$;

create or replace function public.hhmm_min(p text) returns integer
language sql immutable as $$
  select case when p ~ '^\d{1,2}:\d{2}$' then split_part(p, ':', 1)::int * 60 + split_part(p, ':', 2)::int else null end;
$$;

-- Toda conta nova nasce "pendente": só entra no painel depois de aprovada pelo administrador.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, name)
  values (new.id, coalesce(new.email, ''),
          left(coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name', ''), 80))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- regras de acesso (RLS) ----------
alter table public.profiles enable row level security;
alter table public.shops enable row level security;
alter table public.clients enable row level security;
alter table public.bookings enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());

drop policy if exists shops_select on public.shops;
create policy shops_select on public.shops for select to anon, authenticated
  using (public.owner_approved(owner) or owner = auth.uid() or public.is_admin());

drop policy if exists shops_insert on public.shops;
create policy shops_insert on public.shops for insert to authenticated
  with check (owner = auth.uid() and public.is_approved());

drop policy if exists shops_update on public.shops;
create policy shops_update on public.shops for update to authenticated
  using ((owner = auth.uid() and public.is_approved()) or public.is_admin())
  with check ((owner = auth.uid() and public.is_approved()) or public.is_admin());

drop policy if exists shops_delete on public.shops;
create policy shops_delete on public.shops for delete to authenticated
  using ((owner = auth.uid() and public.is_approved()) or public.is_admin());

drop policy if exists clients_all on public.clients;
create policy clients_all on public.clients for all to authenticated
  using (public.owns_shop(shop) or public.is_admin())
  with check (public.owns_shop(shop) or public.is_admin());

drop policy if exists bookings_all on public.bookings;
create policy bookings_all on public.bookings for all to authenticated
  using (public.owns_shop(shop) or public.is_admin())
  with check (public.owns_shop(shop) or public.is_admin());

-- Visitantes não leem tabelas com dados pessoais; só o perfil público dos negócios.
revoke all on public.profiles, public.clients, public.bookings from anon;
revoke insert, update, delete on public.shops from anon;
revoke insert, update, delete on public.profiles from authenticated;
grant select on public.shops to anon, authenticated;
grant select on public.profiles to authenticated;
grant insert, update, delete on public.shops to authenticated;
grant select, insert, update, delete on public.clients, public.bookings to authenticated;

-- ---------- funções públicas (página de agendamento) ----------

-- Horários ocupados: só data, início e fim. Nenhum nome ou telefone sai daqui.
create or replace function public.public_busy(p_shop text, p_from text, p_to text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('date', b.date, 'start', b.start, 'end', b.start + b.dur)), '[]'::jsonb)
  from bookings b
  where b.shop = p_shop and b.date >= p_from and b.date <= p_to and b.status <> 'cancelado';
$$;

-- Avaliações: nota média e os três comentários mais recentes, só com o primeiro nome.
create or replace function public.public_reviews(p_shop text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'count', count(*),
    'avg', coalesce(avg((b.data ->> 'rating')::numeric), 0),
    'list', coalesce((
      select jsonb_agg(x) from (
        select jsonb_build_object(
          'rating', (r.data ->> 'rating')::int, 'review', left(r.data ->> 'review', 300),
          'client', split_part(btrim(coalesce(r.data ->> 'client', '')), ' ', 1),
          'serviceName', r.data ->> 'serviceName', 'ratedAt', r.data ->> 'ratedAt') as x
        from bookings r
        where r.shop = p_shop and (r.data ->> 'rating') ~ '^[1-5]$' and coalesce(r.data ->> 'review', '') <> ''
        order by r.data ->> 'ratedAt' desc nulls last limit 3) t), '[]'::jsonb))
  from bookings b
  where b.shop = p_shop and (b.data ->> 'rating') ~ '^[1-5]$';
$$;

-- Agendamento feito pelo cliente. Preço e duração são calculados aqui, a partir do cadastro do negócio.
create or replace function public.public_book(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_slug text := coalesce(p ->> 'shop', '');
  v_shop jsonb;
  v_date text := coalesce(p ->> 'date', '');
  v_d date;
  v_start integer;
  v_dur integer;
  v_price numeric := 0;
  v_fee numeric := 0;
  v_svc jsonb;
  v_ex jsonb;
  v_extras jsonb := '[]'::jsonb;
  v_names text;
  v_home boolean := coalesce(p ->> 'place', 'shop') = 'home';
  v_name text := left(btrim(regexp_replace(coalesce(p ->> 'name', ''), '[[:cntrl:][:space:]]+', ' ', 'g')), 80);
  v_phone text := regexp_replace(coalesce(p ->> 'phone', ''), '\D', '', 'g');
  v_addr text := left(btrim(regexp_replace(coalesce(p ->> 'address', ''), '[[:cntrl:][:space:]]+', ' ', 'g')), 200);
  v_now timestamp := now() at time zone 'America/Sao_Paulo';
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_lead integer;
  v_h jsonb;
  v_hs integer; v_he integer; v_ps integer; v_pe integer;
  v_id text; v_cid text; v_cdata jsonb;
  v_iso text := to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
begin
  select s.data into v_shop from shops s join profiles pr on pr.id = s.owner
    where s.slug = v_slug and pr.status = 'approved';
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Página de agendamento não encontrada.');
  end if;

  if v_date !~ '^\d{4}-\d{2}-\d{2}$' or coalesce(p ->> 'start', '') !~ '^\d{1,4}$' then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Data ou horário inválido.');
  end if;
  begin
    v_d := v_date::date;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Data inválida.');
  end;
  v_start := (p ->> 'start')::int;

  select x into v_svc from jsonb_array_elements(case when jsonb_typeof(v_shop -> 'services') = 'array' then v_shop -> 'services' else '[]'::jsonb end) x
    where x ->> 'id' = coalesce(p ->> 'serviceId', '') limit 1;
  if v_svc is null or coalesce(v_svc ->> 'min', '') !~ '^\d+(\.\d+)?$' then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Escolha um serviço.');
  end if;
  v_dur := (v_svc ->> 'min')::numeric::int;
  v_price := case when coalesce(v_svc ->> 'price', '') ~ '^\d+(\.\d+)?$' then (v_svc ->> 'price')::numeric else 0 end;
  v_names := v_svc ->> 'name';

  for v_ex in
    select x from jsonb_array_elements(case when jsonb_typeof(v_shop -> 'extras') = 'array' then v_shop -> 'extras' else '[]'::jsonb end) x
    where x ->> 'id' in (select jsonb_array_elements_text(case when jsonb_typeof(p -> 'extras') = 'array' then p -> 'extras' else '[]'::jsonb end))
  loop
    v_dur := v_dur + case when coalesce(v_ex ->> 'min', '') ~ '^\d+(\.\d+)?$' then (v_ex ->> 'min')::numeric::int else 0 end;
    v_price := v_price + case when coalesce(v_ex ->> 'price', '') ~ '^\d+(\.\d+)?$' then (v_ex ->> 'price')::numeric else 0 end;
    v_names := v_names || ' + ' || (v_ex ->> 'name');
    v_extras := v_extras || jsonb_build_array(jsonb_build_object('id', v_ex ->> 'id', 'name', v_ex ->> 'name',
      'price', case when coalesce(v_ex ->> 'price', '') ~ '^\d+(\.\d+)?$' then (v_ex ->> 'price')::numeric else 0 end));
  end loop;

  if v_home then
    if coalesce(v_shop -> 'places' ->> 'home', 'false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Este atendimento não é feito a domicílio.');
    end if;
    if char_length(v_addr) < 8 then
      return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Informe o endereço completo do atendimento.');
    end if;
    v_dur := v_dur + case when coalesce(v_shop ->> 'homeMin', '') ~ '^\d+(\.\d+)?$' then (v_shop ->> 'homeMin')::numeric::int else 0 end;
    v_fee := case when coalesce(v_shop ->> 'homeFee', '') ~ '^\d+(\.\d+)?$' then (v_shop ->> 'homeFee')::numeric else 0 end;
    v_price := v_price + v_fee;
  else
    if coalesce(v_shop -> 'places' ->> 'shop', 'true') = 'false' then
      return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Este atendimento é feito só a domicílio.');
    end if;
    v_addr := '';
  end if;

  if char_length(v_name) < 2 then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Informe seu nome.');
  end if;
  if char_length(v_phone) < 10 or char_length(v_phone) > 13 then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Informe um WhatsApp com DDD.');
  end if;
  if v_dur < 5 or v_start + v_dur > 1440 then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'Horário inválido.');
  end if;

  v_lead := case when coalesce(v_shop ->> 'leadDays', '') ~ '^\d+$' then (v_shop ->> 'leadDays')::int else 0 end;
  if v_d < v_today + v_lead or (v_d = v_today and v_start <= extract(hour from v_now)::int * 60 + extract(minute from v_now)::int) then
    return jsonb_build_object('ok', false, 'error', 'past', 'message', 'Esse horário não está mais disponível. Escolha outro.');
  end if;
  if v_d > v_today + 60 then
    return jsonb_build_object('ok', false, 'error', 'far', 'message', 'Essa data está longe demais. Escolha uma data mais próxima.');
  end if;

  v_h := v_shop -> 'hours' -> extract(dow from v_d)::int;
  v_hs := hhmm_min(v_h ->> 'start'); v_he := hhmm_min(v_h ->> 'end');
  if v_h is null or coalesce(v_h ->> 'open', 'false') <> 'true' or v_hs is null or v_he is null
     or v_start < v_hs or v_start + v_dur > v_he then
    return jsonb_build_object('ok', false, 'error', 'closed', 'message', 'Esse horário está fora do expediente. Escolha outro.');
  end if;
  if coalesce(v_shop -> 'pause' ->> 'on', 'false') = 'true' then
    v_ps := hhmm_min(v_shop -> 'pause' ->> 'start'); v_pe := hhmm_min(v_shop -> 'pause' ->> 'end');
    if v_ps is not null and v_pe is not null and v_start < v_pe and v_start + v_dur > v_ps then
      return jsonb_build_object('ok', false, 'error', 'closed', 'message', 'Esse horário cai no intervalo. Escolha outro.');
    end if;
  end if;

  -- Uma reserva por vez para o mesmo negócio e dia: evita dois clientes no mesmo horário.
  perform pg_advisory_xact_lock(hashtext('agenday:' || v_slug || ':' || v_date));

  if (select count(*) from bookings b where b.shop = v_slug and b.created_at > now() - interval '1 hour'
        and b.data ->> 'origin' = 'cliente') >= 40 then
    return jsonb_build_object('ok', false, 'error', 'limit', 'message', 'Muitos pedidos em pouco tempo. Tente de novo mais tarde ou fale pelo WhatsApp.');
  end if;

  if exists (select 1 from bookings b where b.shop = v_slug and b.date = v_date and b.status <> 'cancelado'
               and v_start < b.start + b.dur and v_start + v_dur > b.start) then
    return jsonb_build_object('ok', false, 'error', 'busy');
  end if;

  select c.id, c.data into v_cid, v_cdata from clients c
    where c.shop = v_slug and bare_phone(c.data ->> 'phone') = bare_phone(v_phone)
    order by c.created_at limit 1;
  if v_cid is null then
    v_cid := 'c' || replace(gen_random_uuid()::text, '-', '');
    insert into clients (id, shop, data) values (v_cid, v_slug, jsonb_build_object(
      'id', v_cid, 'shop', v_slug, 'name', v_name, 'phone', v_phone, 'birth', '', 'cpf', '',
      'address', v_addr, 'notes', '', 'createdAt', v_iso));
  elsif v_home and coalesce(v_cdata ->> 'address', '') = '' then
    update clients set data = jsonb_set(data, '{address}', to_jsonb(v_addr)) where id = v_cid;
  end if;

  v_id := 'b' || replace(gen_random_uuid()::text, '-', '');
  insert into bookings (id, shop, date, start, dur, status, data) values (v_id, v_slug, v_date, v_start, v_dur, 'agendado',
    jsonb_build_object(
      'id', v_id, 'shop', v_slug, 'date', v_date, 'start', v_start, 'dur', v_dur,
      'serviceId', v_svc ->> 'id', 'serviceName', v_names, 'extras', v_extras,
      'price', v_price, 'fee', v_fee, 'place', case when v_home then 'home' else 'shop' end, 'address', v_addr,
      'client', v_name, 'clientId', v_cid, 'phone', v_phone, 'status', 'agendado',
      'origin', 'cliente', 'createdAt', v_iso));

  return jsonb_build_object('ok', true, 'id', v_id, 'clientId', v_cid, 'dur', v_dur, 'price', v_price,
    'fee', v_fee, 'serviceName', v_names, 'extras', v_extras);
end;
$$;

-- "Complete seu cadastro" logo depois de agendar: só preenche campos que ainda estão vazios, e nada é lido.
create or replace function public.public_complete(p_booking text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cid text;
  v_data jsonb;
  v_birth text := coalesce(p ->> 'birth', '');
  v_cpf text := regexp_replace(coalesce(p ->> 'cpf', ''), '\D', '', 'g');
  v_addr text := left(btrim(regexp_replace(coalesce(p ->> 'address', ''), '[[:cntrl:][:space:]]+', ' ', 'g')), 200);
begin
  select b.data ->> 'clientId' into v_cid from bookings b
    where b.id = p_booking and b.data ->> 'origin' = 'cliente' and b.created_at > now() - interval '2 hours';
  if v_cid is null then return jsonb_build_object('ok', false); end if;
  select c.data into v_data from clients c where c.id = v_cid;
  if v_data is null then return jsonb_build_object('ok', false); end if;
  if v_birth ~ '^\d{4}-\d{2}-\d{2}$' and coalesce(v_data ->> 'birth', '') = '' then
    v_data := jsonb_set(v_data, '{birth}', to_jsonb(v_birth));
  end if;
  if char_length(v_cpf) = 11 and coalesce(v_data ->> 'cpf', '') = '' then
    v_data := jsonb_set(v_data, '{cpf}', to_jsonb(v_cpf));
  end if;
  if v_addr <> '' and coalesce(v_data ->> 'address', '') = '' then
    v_data := jsonb_set(v_data, '{address}', to_jsonb(v_addr));
  end if;
  update clients set data = v_data where id = v_cid;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- administração ----------
create or replace function public.admin_set_status(p_user uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'Acesso restrito ao administrador.' using errcode = '42501';
  end if;
  if p_status not in ('pending', 'approved', 'blocked') then
    raise exception 'Situação inválida.';
  end if;
  if p_user = auth.uid() then
    raise exception 'Você não pode alterar a própria conta.';
  end if;
  update profiles set status = p_status where id = p_user;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.admin_set_status(uuid, text) from public, anon;
grant execute on function public.admin_set_status(uuid, text) to authenticated;
grant execute on function public.public_busy(text, text, text), public.public_reviews(text),
  public.public_book(jsonb), public.public_complete(text, jsonb) to anon, authenticated;
grant execute on function public.is_approved(), public.is_admin(), public.owns_shop(text),
  public.owner_approved(uuid) to anon, authenticated;
