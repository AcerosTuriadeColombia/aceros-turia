-- ============================================================================
-- Aceros Turia de Colombia — App de Ruteo Comercial
-- Esquema completo para Supabase (Postgres): tablas, RLS y funciones RPC.
--
-- CÓMO APLICAR:
--   1. Abre el proyecto de Supabase en https://app.supabase.com
--   2. Ve a "SQL Editor" -> "New query"
--   3. Pega TODO este archivo y ejecútalo una sola vez.
--   4. Al final del archivo hay contraseñas iniciales de los asesores
--      (ver tabla de la especificación) — ya quedan hasheadas, no en texto plano.
--
-- DISEÑO DE SEGURIDAD:
--   - Ningún dato sensible (contraseñas, rutas, visitas) es accesible por
--     SELECT/INSERT/UPDATE/DELETE directo desde el cliente (anon key).
--   - Toda la lógica de negocio (login, planeación, aprobación, ejecución,
--     dashboard) vive en funciones RPC "security definer", que son el único
--     punto de entrada expuesto a la app.
--   - La regla de "solo se puede planear lunes o martes" se valida DENTRO de
--     las funciones RPC usando now() del servidor de Postgres (zona horaria
--     America/Bogota), nunca la fecha del navegador del asesor.
-- ============================================================================

create extension if not exists pgcrypto;

-- ============================================================================
-- 1. TABLAS
-- ============================================================================

create table if not exists asesores (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  password_hash text not null,
  es_admin boolean not null default false,
  activo boolean not null default true,
  creado_en timestamptz not null default now()
);

create table if not exists sesiones (
  token uuid primary key default gen_random_uuid(),
  asesor_id uuid not null references asesores(id) on delete cascade,
  creado_en timestamptz not null default now(),
  expira_en timestamptz not null default (now() + interval '16 hours')
);

create table if not exists clientes (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  creado_en timestamptz not null default now(),
  creado_por uuid references asesores(id) on delete set null
);
create unique index if not exists clientes_nombre_lower_idx on clientes (lower(trim(nombre)));

create table if not exists obras (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  cliente_id uuid references clientes(id),
  creado_en timestamptz not null default now(),
  creado_por uuid references asesores(id) on delete set null
);
-- Corrige las FK de creado_por si la tabla ya existía sin "on delete set
-- null" (para poder borrar un asesor que nunca tuvo rutas/visitas).
alter table clientes drop constraint if exists clientes_creado_por_fkey;
alter table clientes add constraint clientes_creado_por_fkey
  foreign key (creado_por) references asesores(id) on delete set null;

alter table obras drop constraint if exists obras_creado_por_fkey;
alter table obras add constraint obras_creado_por_fkey
  foreign key (creado_por) references asesores(id) on delete set null;

-- Las obras se distinguen por cliente: dos constructoras distintas pueden
-- tener cada una una obra con el mismo nombre (ej. "Torre 1").
drop index if exists obras_nombre_lower_idx;
create unique index if not exists obras_cliente_nombre_lower_idx
  on obras (cliente_id, lower(trim(nombre)));

-- Qué asesor(es) atienden a cada cliente. Un cliente puede tener varios
-- (cuentas compartidas); el desplegable de clientes de cada asesor solo
-- muestra los suyos.
create table if not exists cliente_asesores (
  cliente_id uuid not null references clientes(id) on delete cascade,
  asesor_id uuid not null references asesores(id) on delete cascade,
  creado_en timestamptz not null default now(),
  primary key (cliente_id, asesor_id)
);

-- Catálogos abiertos y editables por el administrador:
--   'motivo_visita'    -> Venta, Cobranza, Reclamación, Revisión de precios
--   'resultado_visita' -> Se cotizó, Cliente con stock, ...
--   'motivo_no_visita' -> Cliente ausente, Otro
create table if not exists opciones (
  id uuid primary key default gen_random_uuid(),
  categoria text not null check (categoria in ('motivo_visita','resultado_visita','motivo_no_visita')),
  nombre text not null,
  orden int not null default 0,
  activo boolean not null default true,
  creado_en timestamptz not null default now(),
  unique (categoria, nombre)
);

create table if not exists rutas (
  id uuid primary key default gen_random_uuid(),
  asesor_id uuid not null references asesores(id),
  semana_inicio date not null, -- lunes ISO de la semana que agrupa la ruta
  estado text not null default 'borrador' check (estado in ('borrador','enviada','aceptada')),
  enviada_en timestamptz,
  aprobada_en timestamptz,
  aprobada_por uuid references asesores(id),
  creado_en timestamptz not null default now(),
  unique (asesor_id, semana_inicio)
);

create table if not exists visitas (
  id uuid primary key default gen_random_uuid(),
  ruta_id uuid not null references rutas(id) on delete cascade,
  asesor_id uuid not null references asesores(id),

  cliente_id uuid not null references clientes(id),
  cliente_nombre text not null,
  cliente_es_nuevo boolean not null default false,
  tipo_cliente text not null check (tipo_cliente in ('Constructor','Distribuidor','Arquitecto','Cliente final')),
  obra_id uuid references obras(id),
  obra_nombre text,
  motivo_id uuid references opciones(id),
  fecha_visita date not null,

  -- origen indica cómo se creó el registro
  origen text not null default 'planeacion' check (origen in ('planeacion','no_planeada','seguimiento','reprogramacion')),
  origen_visita_id uuid references visitas(id),

  estado text not null default 'programada' check (estado in ('programada','visitada','no_visitada','cancelada','reprogramada')),

  -- campos de ejecución
  persona_contacto text,
  comentarios text,
  resultado_id uuid references opciones(id),
  motivo_no_visita_id uuid references opciones(id),
  motivo_cancelacion text,
  fecha_reprogramada date,
  seguimiento_fecha date,
  ejecutada_en timestamptz,

  creado_en timestamptz not null default now(),
  actualizado_en timestamptz not null default now()
);

create index if not exists visitas_ruta_idx on visitas (ruta_id);
create index if not exists visitas_asesor_fecha_idx on visitas (asesor_id, fecha_visita);
create index if not exists visitas_estado_idx on visitas (estado);

create table if not exists auditoria (
  id uuid primary key default gen_random_uuid(),
  ruta_id uuid references rutas(id) on delete set null,
  visita_id uuid references visitas(id) on delete set null,
  accion text not null,
  detalle jsonb,
  actor_id uuid references asesores(id) on delete set null,
  creado_en timestamptz not null default now()
);

-- Si la tabla ya existía con las claves foráneas por defecto (sin "on delete
-- set null"), las corrige para que borrar una visita (o un asesor sin
-- historial) no falle ni quede bloqueado por su propio registro de auditoría.
alter table auditoria drop constraint if exists auditoria_ruta_id_fkey;
alter table auditoria add constraint auditoria_ruta_id_fkey
  foreign key (ruta_id) references rutas(id) on delete set null;

alter table auditoria drop constraint if exists auditoria_visita_id_fkey;
alter table auditoria add constraint auditoria_visita_id_fkey
  foreign key (visita_id) references visitas(id) on delete set null;

alter table auditoria drop constraint if exists auditoria_actor_id_fkey;
alter table auditoria add constraint auditoria_actor_id_fkey
  foreign key (actor_id) references asesores(id) on delete set null;

-- Vista con el estado "efectivo": una visita programada cuya fecha ya pasó
-- y nunca se marcó, se reporta como 'vencida' sin necesidad de un job.
create or replace view visitas_vista as
select
  v.*,
  case
    when v.estado = 'programada'
     and v.fecha_visita < (now() at time zone 'America/Bogota')::date
    then 'vencida'
    else v.estado
  end as estado_efectivo
from visitas v;

-- ============================================================================
-- 2. BLOQUEAR ACCESO DIRECTO DESDE EL CLIENTE (RLS + revoke)
-- ============================================================================

alter table asesores enable row level security;
alter table sesiones enable row level security;
alter table rutas enable row level security;
alter table visitas enable row level security;
alter table auditoria enable row level security;
alter table clientes enable row level security;
alter table obras enable row level security;
alter table opciones enable row level security;
alter table cliente_asesores enable row level security;

revoke all on asesores, sesiones, rutas, visitas, auditoria, cliente_asesores from anon, authenticated;

-- Catálogos: lectura pública (no sensible), sin escritura directa.
revoke all on clientes, obras, opciones from anon, authenticated;
grant select on clientes, obras, opciones to anon, authenticated;

drop policy if exists clientes_select on clientes;
create policy clientes_select on clientes for select using (true);
drop policy if exists obras_select on obras;
create policy obras_select on obras for select using (true);
drop policy if exists opciones_select on opciones;
create policy opciones_select on opciones for select using (true);

-- ============================================================================
-- 3. FUNCIONES INTERNAS DE APOYO
-- ============================================================================

-- Resuelve la sesión activa a partir de un token. Lanza excepción si no es válida.
create or replace function fn_sesion_asesor(p_token uuid)
returns table(asesor_id uuid, es_admin boolean, nombre text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select a.id, a.es_admin, a.nombre
    from sesiones s
    join asesores a on a.id = s.asesor_id
    where s.token = p_token
      and s.expira_en > now()
      and a.activo = true;

  if not found then
    raise exception 'Sesión inválida o expirada. Vuelve a iniciar sesión.';
  end if;
end;
$$;

create or replace function fn_es_lunes_o_martes()
returns boolean
language sql
stable
as $$
  select extract(isodow from (now() at time zone 'America/Bogota')) in (1,2);
$$;

create or replace function fn_hoy_bogota()
returns date
language sql
stable
as $$
  select (now() at time zone 'America/Bogota')::date;
$$;

create or replace function fn_lunes_semana(p_fecha date)
returns date
language sql
immutable
as $$
  select p_fecha - ((extract(isodow from p_fecha)::int) - 1);
$$;

-- Inserta el cliente si no existe (comparando sin mayúsculas/espacios) y
-- devuelve su id + si fue creado en este momento (para reportar "cliente nuevo").
create or replace function fn_upsert_cliente(p_nombre text, p_asesor_id uuid)
returns table(id uuid, es_nuevo boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nombre text := trim(p_nombre);
  v_id uuid;
begin
  if v_nombre is null or v_nombre = '' then
    raise exception 'El nombre del cliente es obligatorio.';
  end if;

  insert into clientes (nombre, creado_por)
  values (v_nombre, p_asesor_id)
  on conflict (lower(trim(nombre))) do nothing
  returning clientes.id into v_id;

  if v_id is not null then
    return query select v_id, true;
    return;
  end if;

  select c.id into v_id from clientes c where lower(trim(c.nombre)) = lower(v_nombre);
  return query select v_id, false;
end;
$$;

create or replace function fn_upsert_obra(p_nombre text, p_cliente_id uuid, p_asesor_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nombre text := trim(p_nombre);
  v_id uuid;
begin
  if v_nombre is null or v_nombre = '' then
    return null;
  end if;

  insert into obras (nombre, cliente_id, creado_por)
  values (v_nombre, p_cliente_id, p_asesor_id)
  on conflict (cliente_id, lower(trim(nombre))) do nothing
  returning obras.id into v_id;

  if v_id is not null then
    return v_id;
  end if;

  select o.id into v_id from obras o
  where o.cliente_id = p_cliente_id and lower(trim(o.nombre)) = lower(v_nombre);
  return v_id;
end;
$$;

-- Vincula un cliente con un asesor (quién lo atiende). Se llama cada vez que
-- un asesor usa ese cliente en una visita, para que quede en su lista.
create or replace function fn_asignar_cliente_asesor(p_cliente_id uuid, p_asesor_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into cliente_asesores (cliente_id, asesor_id)
  values (p_cliente_id, p_asesor_id)
  on conflict (cliente_id, asesor_id) do nothing;
$$;

-- Garantiza que exista una ruta (borrador si es nueva) para el asesor en la
-- semana de p_fecha, y devuelve su id.
create or replace function fn_asegurar_ruta(p_asesor_id uuid, p_fecha date)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_semana date := fn_lunes_semana(p_fecha);
  v_id uuid;
begin
  insert into rutas (asesor_id, semana_inicio)
  values (p_asesor_id, v_semana)
  on conflict (asesor_id, semana_inicio) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from rutas where asesor_id = p_asesor_id and semana_inicio = v_semana;
  end if;

  return v_id;
end;
$$;

-- ============================================================================
-- 4. AUTENTICACIÓN
-- ============================================================================

create or replace function rpc_listar_asesores_activos()
returns table(id uuid, nombre text)
language sql
security definer
set search_path = public
as $$
  select id, nombre from asesores where activo = true order by nombre;
$$;

create or replace function rpc_login(p_nombre text, p_password text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_asesor asesores;
  v_token uuid;
begin
  select * into v_asesor from asesores where nombre = p_nombre and activo = true;

  if v_asesor.id is null then
    raise exception 'Usuario no encontrado.';
  end if;

  if v_asesor.password_hash <> crypt(p_password, v_asesor.password_hash) then
    raise exception 'Contraseña incorrecta.';
  end if;

  delete from sesiones where expira_en < now();

  insert into sesiones (asesor_id) values (v_asesor.id) returning token into v_token;

  return json_build_object(
    'token', v_token,
    'asesor_id', v_asesor.id,
    'nombre', v_asesor.nombre,
    'es_admin', v_asesor.es_admin
  );
end;
$$;

create or replace function rpc_cambiar_password(p_token uuid, p_actual text, p_nueva text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_sesion record;
  v_hash text;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);

  select password_hash into v_hash from asesores where id = v_sesion.asesor_id;
  if v_hash <> crypt(p_actual, v_hash) then
    raise exception 'La contraseña actual no es correcta.';
  end if;

  if p_nueva is null or length(p_nueva) < 4 then
    raise exception 'La nueva contraseña debe tener al menos 4 caracteres.';
  end if;

  update asesores set password_hash = crypt(p_nueva, gen_salt('bf')) where id = v_sesion.asesor_id;
  return json_build_object('ok', true);
end;
$$;

-- Alta de nuevo asesor o edición (nombre / activo / reset de contraseña) — solo admin.
create or replace function rpc_admin_upsert_asesor(
  p_token uuid,
  p_asesor_id uuid default null,
  p_nombre text default null,
  p_password text default null,
  p_activo boolean default true
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_sesion record;
  v_id uuid;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede gestionar asesores.';
  end if;

  if p_asesor_id is null then
    if p_nombre is null or trim(p_nombre) = '' or p_password is null or length(p_password) < 4 then
      raise exception 'Nombre y contraseña (mínimo 4 caracteres) son obligatorios para un asesor nuevo.';
    end if;
    insert into asesores (nombre, password_hash)
    values (trim(p_nombre), crypt(p_password, gen_salt('bf')))
    returning id into v_id;
  else
    update asesores set
      nombre = coalesce(trim(p_nombre), nombre),
      activo = coalesce(p_activo, activo),
      password_hash = case when p_password is not null and length(p_password) >= 4
                            then crypt(p_password, gen_salt('bf'))
                            else password_hash end
    where id = p_asesor_id
    returning id into v_id;
  end if;

  return json_build_object('ok', true, 'asesor_id', v_id);
end;
$$;

create or replace function rpc_admin_listar_asesores(p_token uuid)
returns table(id uuid, nombre text, es_admin boolean, activo boolean, creado_en timestamptz)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede ver esta lista.';
  end if;
  return query select a.id, a.nombre, a.es_admin, a.activo, a.creado_en from asesores a order by a.nombre;
end;
$$;

-- Elimina definitivamente a un asesor SOLO si nunca tuvo actividad (sin
-- rutas, visitas ni clientes asignados) — así se conserva el historial de
-- quien ya trabajó en el sistema. Para un asesor con historial, la vía es
-- desactivarlo (rpc_admin_upsert_asesor con p_activo = false).
create or replace function rpc_admin_eliminar_asesor(p_token uuid, p_asesor_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_asesor asesores;
  v_tiene_historial boolean;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede eliminar asesores.';
  end if;

  select * into v_asesor from asesores where id = p_asesor_id;
  if v_asesor.id is null then
    raise exception 'Asesor no encontrado.';
  end if;
  if v_asesor.es_admin then
    raise exception 'No se puede eliminar a un administrador.';
  end if;

  select exists(select 1 from rutas where asesor_id = p_asesor_id)
      or exists(select 1 from visitas where asesor_id = p_asesor_id)
      or exists(select 1 from cliente_asesores where asesor_id = p_asesor_id)
    into v_tiene_historial;

  if v_tiene_historial then
    raise exception 'Este asesor ya tiene rutas, visitas o clientes asignados; no se puede eliminar. Desactívalo en su lugar para conservar su historial.';
  end if;

  delete from asesores where id = p_asesor_id;

  insert into auditoria (accion, actor_id, detalle)
  values ('eliminar_asesor', v_sesion.asesor_id, json_build_object('nombre_eliminado', v_asesor.nombre));

  return json_build_object('ok', true);
end;
$$;

-- ============================================================================
-- 5. CATÁLOGO DE OPCIONES (motivo de visita / resultado / motivo de no visita)
-- ============================================================================

create or replace function rpc_listar_opciones(p_categoria text)
returns table(id uuid, categoria text, nombre text, orden int, activo boolean)
language sql
security definer
set search_path = public
as $$
  select id, categoria, nombre, orden, activo
  from opciones
  where categoria = p_categoria and activo = true
  order by orden, nombre;
$$;

create or replace function rpc_admin_listar_opciones(p_token uuid, p_categoria text default null)
returns table(id uuid, categoria text, nombre text, orden int, activo boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede ver el catálogo completo.';
  end if;
  return query
    select o.id, o.categoria, o.nombre, o.orden, o.activo
    from opciones o
    where p_categoria is null or o.categoria = p_categoria
    order by o.categoria, o.orden, o.nombre;
end;
$$;

create or replace function rpc_admin_upsert_opcion(
  p_token uuid,
  p_id uuid default null,
  p_categoria text default null,
  p_nombre text default null,
  p_orden int default 0,
  p_activo boolean default true
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_id uuid;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede editar este catálogo.';
  end if;

  if p_id is null then
    if p_categoria is null or p_nombre is null or trim(p_nombre) = '' then
      raise exception 'Categoría y nombre son obligatorios.';
    end if;
    insert into opciones (categoria, nombre, orden, activo)
    values (p_categoria, trim(p_nombre), coalesce(p_orden,0), coalesce(p_activo,true))
    returning id into v_id;
  else
    update opciones set
      nombre = coalesce(trim(p_nombre), nombre),
      orden = coalesce(p_orden, orden),
      activo = coalesce(p_activo, activo)
    where id = p_id
    returning id into v_id;
  end if;

  return json_build_object('ok', true, 'id', v_id);
end;
$$;

-- ============================================================================
-- 6. PLANEACIÓN SEMANAL (asesor)
-- ============================================================================

-- Clientes asignados al asesor que llama (para su desplegable de planeación).
-- Un cliente nuevo que el asesor escriba libremente se autoasigna a él al
-- guardarse (ver fn_asignar_cliente_asesor), así que aparecerá aquí después.
create or replace function rpc_mis_clientes(p_token uuid)
returns table(id uuid, nombre text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  return query
    select c.id, c.nombre
    from clientes c
    join cliente_asesores ca on ca.cliente_id = c.id
    where ca.asesor_id = v_sesion.asesor_id
    order by c.nombre;
end;
$$;

create or replace function rpc_mi_ruta_actual(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_semana date := fn_lunes_semana(fn_hoy_bogota());
  v_ruta rutas;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  select * into v_ruta from rutas where asesor_id = v_sesion.asesor_id and semana_inicio = v_semana;

  return json_build_object(
    'semana_inicio', v_semana,
    'puede_planear', fn_es_lunes_o_martes(),
    'ruta', case when v_ruta.id is null then null else json_build_object(
      'id', v_ruta.id, 'estado', v_ruta.estado, 'enviada_en', v_ruta.enviada_en,
      'aprobada_en', v_ruta.aprobada_en
    ) end
  );
end;
$$;

create or replace function rpc_agregar_visita_planeada(
  p_token uuid,
  p_cliente_nombre text,
  p_tipo_cliente text,
  p_obra_nombre text,
  p_motivo_id uuid,
  p_fecha_visita date
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_semana_actual date := fn_lunes_semana(fn_hoy_bogota());
  v_ruta_id uuid;
  v_ruta rutas;
  v_cliente record;
  v_obra_id uuid;
  v_visita_id uuid;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);

  if not fn_es_lunes_o_martes() then
    raise exception 'La planeación de la ruta solo se puede crear o modificar los días lunes y martes.';
  end if;

  if fn_lunes_semana(p_fecha_visita) <> v_semana_actual then
    raise exception 'La fecha de la visita debe pertenecer a la semana actual.';
  end if;

  if p_tipo_cliente not in ('Constructor','Distribuidor','Arquitecto','Cliente final') then
    raise exception 'Tipo de cliente no válido.';
  end if;

  v_ruta_id := fn_asegurar_ruta(v_sesion.asesor_id, p_fecha_visita);
  select * into v_ruta from rutas where id = v_ruta_id;
  if v_ruta.estado <> 'borrador' then
    raise exception 'La ruta ya fue enviada a aprobación; usa "agregar visita no planeada" si necesitas añadir algo nuevo.';
  end if;

  select * into v_cliente from fn_upsert_cliente(p_cliente_nombre, v_sesion.asesor_id);
  perform fn_asignar_cliente_asesor(v_cliente.id, v_sesion.asesor_id);

  if p_tipo_cliente = 'Constructor' and p_obra_nombre is not null and trim(p_obra_nombre) <> '' then
    v_obra_id := fn_upsert_obra(p_obra_nombre, v_cliente.id, v_sesion.asesor_id);
  end if;

  insert into visitas (
    ruta_id, asesor_id, cliente_id, cliente_nombre, cliente_es_nuevo,
    tipo_cliente, obra_id, obra_nombre, motivo_id, fecha_visita, origen, estado
  ) values (
    v_ruta_id, v_sesion.asesor_id, v_cliente.id, trim(p_cliente_nombre), v_cliente.es_nuevo,
    p_tipo_cliente, v_obra_id, case when v_obra_id is not null then trim(p_obra_nombre) else null end,
    p_motivo_id, p_fecha_visita, 'planeacion', 'programada'
  ) returning id into v_visita_id;

  insert into auditoria (ruta_id, visita_id, accion, actor_id, detalle)
  values (v_ruta_id, v_visita_id, 'agregar_visita_planeada', v_sesion.asesor_id, json_build_object('cliente', p_cliente_nombre));

  return json_build_object('ok', true, 'visita_id', v_visita_id, 'ruta_id', v_ruta_id);
end;
$$;

create or replace function rpc_editar_visita_planeada(
  p_token uuid,
  p_visita_id uuid,
  p_cliente_nombre text,
  p_tipo_cliente text,
  p_obra_nombre text,
  p_motivo_id uuid,
  p_fecha_visita date
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_visita visitas;
  v_ruta rutas;
  v_cliente record;
  v_obra_id uuid;
  v_semana_actual date := fn_lunes_semana(fn_hoy_bogota());
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  select * into v_visita from visitas where id = p_visita_id;

  if v_visita.id is null or v_visita.asesor_id <> v_sesion.asesor_id then
    raise exception 'La visita no existe o no te pertenece.';
  end if;
  if v_visita.origen <> 'planeacion' then
    raise exception 'Esta visita no forma parte de la planeación editable.';
  end if;

  select * into v_ruta from rutas where id = v_visita.ruta_id;
  if v_ruta.estado <> 'borrador' then
    raise exception 'La ruta ya fue enviada; no se puede editar.';
  end if;
  if not fn_es_lunes_o_martes() then
    raise exception 'La planeación solo se puede modificar los días lunes y martes.';
  end if;
  if fn_lunes_semana(p_fecha_visita) <> v_semana_actual then
    raise exception 'La fecha de la visita debe pertenecer a la semana actual.';
  end if;
  if p_tipo_cliente not in ('Constructor','Distribuidor','Arquitecto','Cliente final') then
    raise exception 'Tipo de cliente no válido.';
  end if;

  select * into v_cliente from fn_upsert_cliente(p_cliente_nombre, v_sesion.asesor_id);
  perform fn_asignar_cliente_asesor(v_cliente.id, v_sesion.asesor_id);

  if p_tipo_cliente = 'Constructor' and p_obra_nombre is not null and trim(p_obra_nombre) <> '' then
    v_obra_id := fn_upsert_obra(p_obra_nombre, v_cliente.id, v_sesion.asesor_id);
  else
    v_obra_id := null;
  end if;

  update visitas set
    cliente_id = v_cliente.id,
    cliente_nombre = trim(p_cliente_nombre),
    tipo_cliente = p_tipo_cliente,
    obra_id = v_obra_id,
    obra_nombre = case when v_obra_id is not null then trim(p_obra_nombre) else null end,
    motivo_id = p_motivo_id,
    fecha_visita = p_fecha_visita,
    actualizado_en = now()
  where id = p_visita_id;

  insert into auditoria (ruta_id, visita_id, accion, actor_id)
  values (v_visita.ruta_id, p_visita_id, 'editar_visita_planeada', v_sesion.asesor_id);

  return json_build_object('ok', true);
end;
$$;

create or replace function rpc_eliminar_visita_planeada(p_token uuid, p_visita_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_visita visitas;
  v_ruta rutas;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  select * into v_visita from visitas where id = p_visita_id;

  if v_visita.id is null or v_visita.asesor_id <> v_sesion.asesor_id then
    raise exception 'La visita no existe o no te pertenece.';
  end if;
  if v_visita.origen <> 'planeacion' then
    raise exception 'Solo se pueden eliminar visitas de la planeación.';
  end if;

  select * into v_ruta from rutas where id = v_visita.ruta_id;
  if v_ruta.estado <> 'borrador' then
    raise exception 'La ruta ya fue enviada; no se puede eliminar.';
  end if;
  if not fn_es_lunes_o_martes() then
    raise exception 'La planeación solo se puede modificar los días lunes y martes.';
  end if;

  insert into auditoria (ruta_id, visita_id, accion, actor_id)
  values (v_ruta.id, p_visita_id, 'eliminar_visita_planeada', v_sesion.asesor_id);

  delete from visitas where id = p_visita_id;

  return json_build_object('ok', true);
end;
$$;

create or replace function rpc_enviar_ruta(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_semana date := fn_lunes_semana(fn_hoy_bogota());
  v_ruta rutas;
  v_total int;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);

  if not fn_es_lunes_o_martes() then
    raise exception 'La ruta solo se puede enviar los días lunes y martes.';
  end if;

  select * into v_ruta from rutas where asesor_id = v_sesion.asesor_id and semana_inicio = v_semana;
  if v_ruta.id is null then
    raise exception 'No has creado ninguna visita para esta semana.';
  end if;
  if v_ruta.estado <> 'borrador' then
    raise exception 'Esta ruta ya fue enviada.';
  end if;

  select count(*) into v_total from visitas where ruta_id = v_ruta.id;
  if v_total = 0 then
    raise exception 'Agrega al menos una visita antes de enviar la ruta.';
  end if;

  update rutas set estado = 'enviada', enviada_en = now() where id = v_ruta.id;

  insert into auditoria (ruta_id, accion, actor_id)
  values (v_ruta.id, 'enviar_ruta', v_sesion.asesor_id);

  return json_build_object('ok', true, 'ruta_id', v_ruta.id);
end;
$$;

-- Visita no planeada: excepción permitida cualquier día de la semana.
create or replace function rpc_agregar_visita_no_planeada(
  p_token uuid,
  p_cliente_nombre text,
  p_tipo_cliente text,
  p_obra_nombre text,
  p_motivo_id uuid,
  p_fecha_visita date default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_fecha date := coalesce(p_fecha_visita, fn_hoy_bogota());
  v_ruta_id uuid;
  v_cliente record;
  v_obra_id uuid;
  v_visita_id uuid;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);

  if p_tipo_cliente not in ('Constructor','Distribuidor','Arquitecto','Cliente final') then
    raise exception 'Tipo de cliente no válido.';
  end if;

  v_ruta_id := fn_asegurar_ruta(v_sesion.asesor_id, v_fecha);

  select * into v_cliente from fn_upsert_cliente(p_cliente_nombre, v_sesion.asesor_id);
  perform fn_asignar_cliente_asesor(v_cliente.id, v_sesion.asesor_id);

  if p_tipo_cliente = 'Constructor' and p_obra_nombre is not null and trim(p_obra_nombre) <> '' then
    v_obra_id := fn_upsert_obra(p_obra_nombre, v_cliente.id, v_sesion.asesor_id);
  end if;

  insert into visitas (
    ruta_id, asesor_id, cliente_id, cliente_nombre, cliente_es_nuevo,
    tipo_cliente, obra_id, obra_nombre, motivo_id, fecha_visita, origen, estado
  ) values (
    v_ruta_id, v_sesion.asesor_id, v_cliente.id, trim(p_cliente_nombre), v_cliente.es_nuevo,
    p_tipo_cliente, v_obra_id, case when v_obra_id is not null then trim(p_obra_nombre) else null end,
    p_motivo_id, v_fecha, 'no_planeada', 'programada'
  ) returning id into v_visita_id;

  insert into auditoria (ruta_id, visita_id, accion, actor_id, detalle)
  values (v_ruta_id, v_visita_id, 'agregar_visita_no_planeada', v_sesion.asesor_id, json_build_object('cliente', p_cliente_nombre));

  return json_build_object('ok', true, 'visita_id', v_visita_id, 'ruta_id', v_ruta_id);
end;
$$;

-- ============================================================================
-- 7. APROBACIÓN (administrador)
-- ============================================================================

create or replace function rpc_admin_listar_rutas(p_token uuid, p_estado text default null)
returns table(
  id uuid, asesor_id uuid, asesor_nombre text, semana_inicio date, estado text,
  enviada_en timestamptz, aprobada_en timestamptz, total_visitas bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede ver esta información.';
  end if;

  return query
    select r.id, r.asesor_id, a.nombre, r.semana_inicio, r.estado, r.enviada_en, r.aprobada_en,
           (select count(*) from visitas v where v.ruta_id = r.id)
    from rutas r
    join asesores a on a.id = r.asesor_id
    where p_estado is null or r.estado = p_estado
    order by r.semana_inicio desc, a.nombre;
end;
$$;

create or replace function rpc_admin_aprobar_ruta(p_token uuid, p_ruta_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_ruta rutas;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede aprobar rutas.';
  end if;

  select * into v_ruta from rutas where id = p_ruta_id;
  if v_ruta.id is null then
    raise exception 'Ruta no encontrada.';
  end if;
  if v_ruta.estado <> 'enviada' then
    raise exception 'Solo se pueden aprobar rutas en estado "enviada".';
  end if;

  update rutas set estado = 'aceptada', aprobada_en = now(), aprobada_por = v_sesion.asesor_id
  where id = p_ruta_id;

  insert into auditoria (ruta_id, accion, actor_id)
  values (p_ruta_id, 'aprobar_ruta', v_sesion.asesor_id);

  return json_build_object('ok', true);
end;
$$;

-- El administrador puede eliminar cualquier visita (de prueba, duplicada o
-- por corrección), sin las restricciones de día/estado que aplican al asesor.
create or replace function rpc_admin_eliminar_visita(p_token uuid, p_visita_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_visita visitas;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede eliminar visitas.';
  end if;

  select * into v_visita from visitas where id = p_visita_id;
  if v_visita.id is null then
    raise exception 'La visita no existe.';
  end if;

  insert into auditoria (ruta_id, visita_id, accion, actor_id, detalle)
  values (v_visita.ruta_id, p_visita_id, 'admin_eliminar_visita', v_sesion.asesor_id,
          json_build_object('cliente', v_visita.cliente_nombre, 'fecha_visita', v_visita.fecha_visita));

  delete from visitas where id = p_visita_id;

  return json_build_object('ok', true);
end;
$$;

-- ============================================================================
-- 8. LISTADOS DE VISITAS (planeación + ejecución)
-- ============================================================================

create or replace function rpc_listar_visitas_de_ruta(p_token uuid, p_ruta_id uuid)
returns setof visitas_vista
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_ruta rutas;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  select * into v_ruta from rutas where id = p_ruta_id;

  if v_ruta.id is null then
    raise exception 'Ruta no encontrada.';
  end if;
  if not v_sesion.es_admin and v_ruta.asesor_id <> v_sesion.asesor_id then
    raise exception 'No tienes acceso a esta ruta.';
  end if;

  return query select * from visitas_vista where ruta_id = p_ruta_id order by fecha_visita;
end;
$$;

create or replace function rpc_listar_mis_visitas(p_token uuid, p_desde date default null, p_hasta date default null)
returns setof visitas_vista
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  return query
    select * from visitas_vista
    where asesor_id = v_sesion.asesor_id
      and (p_desde is null or fecha_visita >= p_desde)
      and (p_hasta is null or fecha_visita <= p_hasta)
    order by fecha_visita;
end;
$$;

-- ============================================================================
-- 9. EJECUCIÓN DE LA VISITA (asesor)
-- ============================================================================

create or replace function rpc_marcar_visitada(
  p_token uuid,
  p_visita_id uuid,
  p_persona_contacto text,
  p_comentarios text,
  p_resultado_id uuid,
  p_seguimiento_fecha date default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_visita visitas;
  v_nueva_id uuid;
  v_nueva_ruta uuid;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  select * into v_visita from visitas where id = p_visita_id;

  if v_visita.id is null or (v_visita.asesor_id <> v_sesion.asesor_id and not v_sesion.es_admin) then
    raise exception 'La visita no existe o no te pertenece.';
  end if;

  update visitas set
    estado = 'visitada',
    persona_contacto = p_persona_contacto,
    comentarios = p_comentarios,
    resultado_id = p_resultado_id,
    seguimiento_fecha = p_seguimiento_fecha,
    ejecutada_en = now(),
    actualizado_en = now()
  where id = p_visita_id;

  insert into auditoria (ruta_id, visita_id, accion, actor_id)
  values (v_visita.ruta_id, p_visita_id, 'marcar_visitada', v_sesion.asesor_id);

  if p_seguimiento_fecha is not null then
    v_nueva_ruta := fn_asegurar_ruta(v_visita.asesor_id, p_seguimiento_fecha);

    insert into visitas (
      ruta_id, asesor_id, cliente_id, cliente_nombre, cliente_es_nuevo,
      tipo_cliente, obra_id, obra_nombre, motivo_id, fecha_visita,
      origen, origen_visita_id, estado
    ) values (
      v_nueva_ruta, v_visita.asesor_id, v_visita.cliente_id, v_visita.cliente_nombre, false,
      v_visita.tipo_cliente, v_visita.obra_id, v_visita.obra_nombre, null, p_seguimiento_fecha,
      'seguimiento', p_visita_id, 'programada'
    ) returning id into v_nueva_id;

    insert into auditoria (ruta_id, visita_id, accion, actor_id, detalle)
    values (v_nueva_ruta, v_nueva_id, 'crear_seguimiento', v_sesion.asesor_id, json_build_object('origen_visita_id', p_visita_id));
  end if;

  return json_build_object('ok', true, 'seguimiento_visita_id', v_nueva_id);
end;
$$;

create or replace function rpc_marcar_no_visitada(p_token uuid, p_visita_id uuid, p_motivo_no_visita_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_visita visitas;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  select * into v_visita from visitas where id = p_visita_id;

  if v_visita.id is null or (v_visita.asesor_id <> v_sesion.asesor_id and not v_sesion.es_admin) then
    raise exception 'La visita no existe o no te pertenece.';
  end if;

  update visitas set
    estado = 'no_visitada',
    motivo_no_visita_id = p_motivo_no_visita_id,
    ejecutada_en = now(),
    actualizado_en = now()
  where id = p_visita_id;

  insert into auditoria (ruta_id, visita_id, accion, actor_id)
  values (v_visita.ruta_id, p_visita_id, 'marcar_no_visitada', v_sesion.asesor_id);

  return json_build_object('ok', true);
end;
$$;

create or replace function rpc_marcar_cancelada(p_token uuid, p_visita_id uuid, p_motivo text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_visita visitas;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  select * into v_visita from visitas where id = p_visita_id;

  if v_visita.id is null or (v_visita.asesor_id <> v_sesion.asesor_id and not v_sesion.es_admin) then
    raise exception 'La visita no existe o no te pertenece.';
  end if;

  update visitas set
    estado = 'cancelada',
    motivo_cancelacion = p_motivo,
    ejecutada_en = now(),
    actualizado_en = now()
  where id = p_visita_id;

  insert into auditoria (ruta_id, visita_id, accion, actor_id)
  values (v_visita.ruta_id, p_visita_id, 'marcar_cancelada', v_sesion.asesor_id);

  return json_build_object('ok', true);
end;
$$;

create or replace function rpc_marcar_reprogramada(p_token uuid, p_visita_id uuid, p_nueva_fecha date)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_visita visitas;
  v_nueva_ruta uuid;
  v_nueva_id uuid;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  select * into v_visita from visitas where id = p_visita_id;

  if v_visita.id is null or (v_visita.asesor_id <> v_sesion.asesor_id and not v_sesion.es_admin) then
    raise exception 'La visita no existe o no te pertenece.';
  end if;

  update visitas set
    estado = 'reprogramada',
    fecha_reprogramada = p_nueva_fecha,
    ejecutada_en = now(),
    actualizado_en = now()
  where id = p_visita_id;

  v_nueva_ruta := fn_asegurar_ruta(v_visita.asesor_id, p_nueva_fecha);

  insert into visitas (
    ruta_id, asesor_id, cliente_id, cliente_nombre, cliente_es_nuevo,
    tipo_cliente, obra_id, obra_nombre, motivo_id, fecha_visita,
    origen, origen_visita_id, estado
  ) values (
    v_nueva_ruta, v_visita.asesor_id, v_visita.cliente_id, v_visita.cliente_nombre, false,
    v_visita.tipo_cliente, v_visita.obra_id, v_visita.obra_nombre, v_visita.motivo_id, p_nueva_fecha,
    'reprogramacion', p_visita_id, 'programada'
  ) returning id into v_nueva_id;

  insert into auditoria (ruta_id, visita_id, accion, actor_id, detalle)
  values (v_nueva_ruta, v_nueva_id, 'crear_reprogramacion', v_sesion.asesor_id, json_build_object('origen_visita_id', p_visita_id));

  return json_build_object('ok', true, 'nueva_visita_id', v_nueva_id);
end;
$$;

-- ============================================================================
-- 10. DASHBOARD (administrador)
-- ============================================================================

create or replace function rpc_admin_dashboard(
  p_token uuid,
  p_desde date,
  p_hasta date,
  p_asesor_ids uuid[] default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_programadas bigint;
  v_visitadas bigint;
  v_no_realizadas bigint;
  v_clientes_nuevos bigint;
  v_obras json;
  v_por_asesor json;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede ver el dashboard.';
  end if;

  select count(*) into v_programadas
  from visitas_vista
  where fecha_visita between p_desde and p_hasta
    and (p_asesor_ids is null or asesor_id = any(p_asesor_ids));

  select count(*) into v_visitadas
  from visitas_vista
  where fecha_visita between p_desde and p_hasta
    and estado_efectivo = 'visitada'
    and (p_asesor_ids is null or asesor_id = any(p_asesor_ids));

  select count(*) into v_no_realizadas
  from visitas_vista
  where fecha_visita between p_desde and p_hasta
    and estado_efectivo in ('cancelada','no_visitada','vencida')
    and (p_asesor_ids is null or asesor_id = any(p_asesor_ids));

  select count(*) into v_clientes_nuevos
  from visitas_vista
  where fecha_visita between p_desde and p_hasta
    and cliente_es_nuevo = true
    and (p_asesor_ids is null or asesor_id = any(p_asesor_ids));

  select coalesce(json_agg(t), '[]'::json) into v_obras
  from (
    select cliente_nombre as constructora, count(distinct obra_nombre) as obras_visitadas,
           count(*) as visitas
    from visitas_vista
    where tipo_cliente = 'Constructor'
      and obra_nombre is not null
      and fecha_visita between p_desde and p_hasta
      and (p_asesor_ids is null or asesor_id = any(p_asesor_ids))
    group by cliente_nombre
    order by visitas desc
  ) t;

  select coalesce(json_agg(t), '[]'::json) into v_por_asesor
  from (
    select a.nombre as asesor,
           count(*) filter (where vv.fecha_visita between p_desde and p_hasta) as programadas,
           count(*) filter (where vv.estado_efectivo = 'visitada' and vv.fecha_visita between p_desde and p_hasta) as visitadas,
           count(*) filter (where vv.estado_efectivo in ('cancelada','no_visitada','vencida') and vv.fecha_visita between p_desde and p_hasta) as no_realizadas
    from asesores a
    left join visitas_vista vv on vv.asesor_id = a.id
    where a.es_admin = false and (p_asesor_ids is null or a.id = any(p_asesor_ids))
    group by a.nombre
    order by a.nombre
  ) t;

  return json_build_object(
    'programadas', v_programadas,
    'visitadas', v_visitadas,
    'no_realizadas', v_no_realizadas,
    'clientes_nuevos', v_clientes_nuevos,
    'obras_por_constructora', v_obras,
    'por_asesor', v_por_asesor
  );
end;
$$;

-- Dashboard personal: cada asesor ve solo sus propios números, nunca los
-- de los demás (a diferencia de rpc_admin_dashboard, no requiere ser admin).
create or replace function rpc_mi_dashboard(p_token uuid, p_desde date, p_hasta date)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_programadas bigint;
  v_visitadas bigint;
  v_no_realizadas bigint;
  v_clientes_nuevos bigint;
  v_obras json;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);

  select count(*) into v_programadas
  from visitas_vista
  where asesor_id = v_sesion.asesor_id and fecha_visita between p_desde and p_hasta;

  select count(*) into v_visitadas
  from visitas_vista
  where asesor_id = v_sesion.asesor_id and estado_efectivo = 'visitada'
    and fecha_visita between p_desde and p_hasta;

  select count(*) into v_no_realizadas
  from visitas_vista
  where asesor_id = v_sesion.asesor_id and estado_efectivo in ('cancelada','no_visitada','vencida')
    and fecha_visita between p_desde and p_hasta;

  select count(*) into v_clientes_nuevos
  from visitas_vista
  where asesor_id = v_sesion.asesor_id and cliente_es_nuevo = true
    and fecha_visita between p_desde and p_hasta;

  select coalesce(json_agg(t), '[]'::json) into v_obras
  from (
    select cliente_nombre as constructora, count(distinct obra_nombre) as obras_visitadas,
           count(*) as visitas
    from visitas_vista
    where asesor_id = v_sesion.asesor_id
      and tipo_cliente = 'Constructor'
      and obra_nombre is not null
      and fecha_visita between p_desde and p_hasta
    group by cliente_nombre
    order by visitas desc
  ) t;

  return json_build_object(
    'programadas', v_programadas,
    'visitadas', v_visitadas,
    'no_realizadas', v_no_realizadas,
    'clientes_nuevos', v_clientes_nuevos,
    'obras_por_constructora', v_obras
  );
end;
$$;

-- Clientes del propio asesor sin una visita "visitada" en al menos p_dias
-- días (o nunca visitados) — solo entre los clientes que tiene asignados.
create or replace function rpc_mis_clientes_sin_visitar(p_token uuid, p_dias int default 30)
returns table(
  cliente_id uuid,
  cliente_nombre text,
  ultima_visita date,
  dias_sin_visita int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);

  return query
    select c.id, c.nombre, u.ultima_visita,
           case when u.ultima_visita is null then null
                else (fn_hoy_bogota() - u.ultima_visita)::int end
    from clientes c
    join cliente_asesores ca on ca.cliente_id = c.id and ca.asesor_id = v_sesion.asesor_id
    left join lateral (
      select v.fecha_visita as ultima_visita
      from visitas v
      where v.cliente_id = c.id and v.asesor_id = v_sesion.asesor_id and v.estado = 'visitada'
      order by v.fecha_visita desc
      limit 1
    ) u on true
    where u.ultima_visita is null or (fn_hoy_bogota() - u.ultima_visita) >= p_dias
    order by u.ultima_visita asc nulls first;
end;
$$;

-- ============================================================================
-- 10.1. CATÁLOGO DE CLIENTES: importación masiva e historial por cliente
-- ============================================================================

-- Importa muchos nombres de cliente de una vez (ej. pegados desde un Excel).
-- Reutiliza fn_upsert_cliente, así que es seguro repetir nombres que ya existan.
-- Corrige una función anterior con menos parámetros: si no se elimina,
-- Postgres la deja como una sobrecarga aparte y las llamadas quedan
-- ambiguas ("Could not choose the best candidate function").
drop function if exists rpc_admin_importar_clientes(uuid, text[]);

create or replace function rpc_admin_importar_clientes(p_token uuid, p_nombres text[], p_asesor_id uuid default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
  v_nombre text;
  v_res record;
  v_creados int := 0;
  v_existentes int := 0;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede importar clientes.';
  end if;

  foreach v_nombre in array p_nombres loop
    if trim(coalesce(v_nombre, '')) = '' then
      continue;
    end if;
    select * into v_res from fn_upsert_cliente(v_nombre, v_sesion.asesor_id);
    if v_res.es_nuevo then
      v_creados := v_creados + 1;
    else
      v_existentes := v_existentes + 1;
    end if;
    if p_asesor_id is not null then
      perform fn_asignar_cliente_asesor(v_res.id, p_asesor_id);
    end if;
  end loop;

  return json_build_object('ok', true, 'creados', v_creados, 'existentes', v_existentes);
end;
$$;

-- Lista clientes con sus asesores asignados (chips), para el panel de admin.
-- p_texto filtra por nombre de cliente (búsqueda parcial, sin mayúsculas).
create or replace function rpc_admin_listar_clientes(p_token uuid, p_texto text default null)
returns table(cliente_id uuid, cliente_nombre text, asesores json)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede ver esta lista.';
  end if;

  return query
    select c.id, c.nombre,
           coalesce((
             select json_agg(json_build_object('id', a.id, 'nombre', a.nombre) order by a.nombre)
             from cliente_asesores ca
             join asesores a on a.id = ca.asesor_id
             where ca.cliente_id = c.id
           ), '[]'::json)
    from clientes c
    where p_texto is null or c.nombre ilike '%' || p_texto || '%'
    order by c.nombre
    limit 200;
end;
$$;

create or replace function rpc_admin_asignar_cliente(p_token uuid, p_cliente_id uuid, p_asesor_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede asignar clientes.';
  end if;
  perform fn_asignar_cliente_asesor(p_cliente_id, p_asesor_id);
  return json_build_object('ok', true);
end;
$$;

create or replace function rpc_admin_desasignar_cliente(p_token uuid, p_cliente_id uuid, p_asesor_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede quitar asignaciones.';
  end if;
  delete from cliente_asesores where cliente_id = p_cliente_id and asesor_id = p_asesor_id;
  return json_build_object('ok', true);
end;
$$;

-- Historial completo de visitas de un cliente puntual (para el dashboard).
create or replace function rpc_admin_historial_cliente(p_token uuid, p_cliente_id uuid)
returns table(
  visita_id uuid,
  fecha_visita date,
  asesor_nombre text,
  tipo_cliente text,
  obra_nombre text,
  motivo_id uuid,
  estado text,
  estado_efectivo text,
  persona_contacto text,
  comentarios text,
  resultado_id uuid,
  motivo_no_visita_id uuid,
  motivo_cancelacion text,
  fecha_reprogramada date
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede ver el historial de clientes.';
  end if;

  return query
    select vv.id, vv.fecha_visita, a.nombre, vv.tipo_cliente, vv.obra_nombre,
           vv.motivo_id, vv.estado, vv.estado_efectivo, vv.persona_contacto, vv.comentarios,
           vv.resultado_id, vv.motivo_no_visita_id, vv.motivo_cancelacion, vv.fecha_reprogramada
    from visitas_vista vv
    join asesores a on a.id = vv.asesor_id
    where vv.cliente_id = p_cliente_id
    order by vv.fecha_visita desc;
end;
$$;

-- Clientes sin una visita "visitada" en al menos p_dias días (o nunca visitados).
-- Misma corrección que arriba: elimina la sobrecarga con menos parámetros.
drop function if exists rpc_admin_clientes_sin_visitar(uuid, int);

create or replace function rpc_admin_clientes_sin_visitar(
  p_token uuid,
  p_dias int default 30,
  p_asesor_ids uuid[] default null
)
returns table(
  cliente_id uuid,
  cliente_nombre text,
  ultima_visita date,
  dias_sin_visita int,
  ultimo_asesor text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sesion record;
begin
  select * into v_sesion from fn_sesion_asesor(p_token);
  if not v_sesion.es_admin then
    raise exception 'Solo el administrador puede ver esta información.';
  end if;

  return query
    select c.id, c.nombre, u.ultima_visita,
           case when u.ultima_visita is null then null
                else (fn_hoy_bogota() - u.ultima_visita)::int end,
           u.ultimo_asesor
    from clientes c
    left join lateral (
      select v.fecha_visita as ultima_visita, a.nombre as ultimo_asesor
      from visitas v
      join asesores a on a.id = v.asesor_id
      where v.cliente_id = c.id and v.estado = 'visitada'
      order by v.fecha_visita desc
      limit 1
    ) u on true
    where (u.ultima_visita is null or (fn_hoy_bogota() - u.ultima_visita) >= p_dias)
      and (
        p_asesor_ids is null
        or exists (
          select 1 from cliente_asesores ca
          where ca.cliente_id = c.id and ca.asesor_id = any(p_asesor_ids)
        )
      )
    order by u.ultima_visita asc nulls first;
end;
$$;

-- ============================================================================
-- 11. PERMISOS DE EJECUCIÓN (RPC) PARA anon / authenticated
-- ============================================================================

grant execute on function
  rpc_listar_asesores_activos(),
  rpc_login(text, text),
  rpc_cambiar_password(uuid, text, text),
  rpc_admin_upsert_asesor(uuid, uuid, text, text, boolean),
  rpc_admin_listar_asesores(uuid),
  rpc_admin_eliminar_asesor(uuid, uuid),
  rpc_listar_opciones(text),
  rpc_admin_listar_opciones(uuid, text),
  rpc_admin_upsert_opcion(uuid, uuid, text, text, int, boolean),
  rpc_mi_ruta_actual(uuid),
  rpc_agregar_visita_planeada(uuid, text, text, text, uuid, date),
  rpc_editar_visita_planeada(uuid, uuid, text, text, text, uuid, date),
  rpc_eliminar_visita_planeada(uuid, uuid),
  rpc_enviar_ruta(uuid),
  rpc_agregar_visita_no_planeada(uuid, text, text, text, uuid, date),
  rpc_admin_listar_rutas(uuid, text),
  rpc_admin_aprobar_ruta(uuid, uuid),
  rpc_admin_eliminar_visita(uuid, uuid),
  rpc_listar_visitas_de_ruta(uuid, uuid),
  rpc_listar_mis_visitas(uuid, date, date),
  rpc_marcar_visitada(uuid, uuid, text, text, uuid, date),
  rpc_marcar_no_visitada(uuid, uuid, uuid),
  rpc_marcar_cancelada(uuid, uuid, text),
  rpc_marcar_reprogramada(uuid, uuid, date),
  rpc_admin_dashboard(uuid, date, date, uuid[]),
  rpc_mi_dashboard(uuid, date, date),
  rpc_mis_clientes_sin_visitar(uuid, int),
  rpc_admin_importar_clientes(uuid, text[], uuid),
  rpc_admin_historial_cliente(uuid, uuid),
  rpc_admin_clientes_sin_visitar(uuid, int, uuid[]),
  rpc_mis_clientes(uuid),
  rpc_admin_listar_clientes(uuid, text),
  rpc_admin_asignar_cliente(uuid, uuid, uuid),
  rpc_admin_desasignar_cliente(uuid, uuid, uuid)
to anon, authenticated;

-- ============================================================================
-- 12. DATOS INICIALES (seed)
-- ============================================================================

-- Asesores y contraseñas iniciales (últimos 4 dígitos del celular).
-- Mauricio Lopera es además el administrador (gerente comercial).
insert into asesores (nombre, password_hash, es_admin) values
  ('Mauricio Lopera',          crypt('0706', gen_salt('bf')), true),
  ('Ricardo Alexis Moncada',   crypt('0311', gen_salt('bf')), false),
  ('Katty Berrio',             crypt('0902', gen_salt('bf')), false),
  ('Olmes Ortega',             crypt('2602', gen_salt('bf')), false),
  ('Jorge Calvo',              crypt('1611', gen_salt('bf')), false),
  ('Diego Quintero',           crypt('0305', gen_salt('bf')), false)
on conflict (nombre) do nothing;

insert into opciones (categoria, nombre, orden) values
  ('motivo_visita', 'Venta', 1),
  ('motivo_visita', 'Cobranza', 2),
  ('motivo_visita', 'Reclamación', 3),
  ('motivo_visita', 'Revisión de precios', 4),

  ('resultado_visita', 'Se cotizó', 1),
  ('resultado_visita', 'Cliente con stock (no compró)', 2),
  ('resultado_visita', 'Sin stock en planta', 3),
  ('resultado_visita', 'Competencia más barata', 4),
  ('resultado_visita', 'Cobranza realizada', 5),
  ('resultado_visita', 'Reclamación atendida', 6),
  ('resultado_visita', 'Otro', 7),

  ('motivo_no_visita', 'Cliente ausente / no estaba en oficina', 1),
  ('motivo_no_visita', 'Otro', 2)
on conflict (categoria, nombre) do nothing;

-- ============================================================================
-- Fin del esquema.
-- ============================================================================
