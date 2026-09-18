// Aceros Turia — App de Ruteo Comercial — lógica compartida
const RUTEO_SUPABASE_URL = 'https://zullhslppokhhswdairh.supabase.co';
const RUTEO_SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inp1bGxoc2xwcG9raGhzd2RhaXJoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc0MDU4MDEsImV4cCI6MjA5Mjk4MTgwMX0.NalrI8rLLW3m78dqVGrlmZTdJ_h6zRXzIP2MlM4gVMU';

const RUTEO_SESSION_KEY = 'ruteo_sesion_v1';

function ruteoGetSesion() {
  try {
    const raw = localStorage.getItem(RUTEO_SESSION_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch (e) { return null; }
}

function ruteoSetSesion(sesion) {
  localStorage.setItem(RUTEO_SESSION_KEY, JSON.stringify(sesion));
}

function ruteoLogout() {
  localStorage.removeItem(RUTEO_SESSION_KEY);
  window.location.href = 'aceros-turia-ruteo-login.html';
}

// Redirige a login si no hay sesión; devuelve la sesión si existe.
function ruteoRequireSesion() {
  const s = ruteoGetSesion();
  if (!s || !s.token) {
    window.location.href = 'aceros-turia-ruteo-login.html';
    return null;
  }
  return s;
}

// Llama a una función RPC de Supabase (Postgres). Lanza Error con el mensaje
// del servidor si la función falla (por ejemplo, una validación de negocio).
async function ruteoRpc(nombreFn, params = {}) {
  let res;
  try {
    res = await fetch(`${RUTEO_SUPABASE_URL}/rest/v1/rpc/${nombreFn}`, {
      method: 'POST',
      headers: {
        'apikey': RUTEO_SUPABASE_KEY,
        'Authorization': `Bearer ${RUTEO_SUPABASE_KEY}`,
        'Content-Type': 'application/json',
        'Prefer': 'return=representation'
      },
      body: JSON.stringify(params)
    });
  } catch (e) {
    throw new Error('No se pudo conectar con el servidor. Revisa tu conexión.');
  }

  let body = null;
  const text = await res.text();
  try { body = text ? JSON.parse(text) : null; } catch (e) { body = text; }

  if (!res.ok) {
    const msg = (body && (body.message || body.hint)) || 'Ocurrió un error inesperado.';
    throw new Error(msg);
  }
  return body;
}

// Helper para llamadas RPC autenticadas: inyecta el token de sesión como
// p_token y redirige a login si el servidor reporta sesión inválida.
async function ruteoRpcAuth(nombreFn, params = {}) {
  const s = ruteoRequireSesion();
  if (!s) return null;
  try {
    return await ruteoRpc(nombreFn, { p_token: s.token, ...params });
  } catch (e) {
    if (/sesión inválida|expirada/i.test(e.message)) {
      ruteoLogout();
      return null;
    }
    throw e;
  }
}

// Lectura directa de catálogos públicos (clientes, obras, opciones) vía REST.
// No requiere sesión: son datos no sensibles y de solo lectura para el cliente.
async function ruteoSelect(tabla, queryString = '') {
  const res = await fetch(`${RUTEO_SUPABASE_URL}/rest/v1/${tabla}?${queryString}`, {
    headers: {
      'apikey': RUTEO_SUPABASE_KEY,
      'Authorization': `Bearer ${RUTEO_SUPABASE_KEY}`
    }
  });
  if (!res.ok) throw new Error('No se pudo cargar el catálogo ' + tabla);
  return res.json();
}

// ---- Fechas / semanas (solo para UI; el servidor valida con su propio reloj) ----

function ruteoHoyStr() {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

function ruteoLunesDeSemana(fechaStr) {
  const d = new Date(fechaStr + 'T00:00:00');
  const isoDow = d.getDay() === 0 ? 7 : d.getDay();
  d.setDate(d.getDate() - (isoDow - 1));
  return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
}

function ruteoEsLunesOMartes() {
  const dow = new Date().getDay(); // 0=Dom
  return dow === 1 || dow === 2;
}

function ruteoFormatFecha(fechaStr) {
  if (!fechaStr) return '—';
  const d = new Date(fechaStr + 'T00:00:00');
  return d.toLocaleDateString('es-CO', { day: '2-digit', month: 'short', year: 'numeric' });
}

function ruteoDiaSemana(fechaStr) {
  const dias = ['Domingo','Lunes','Martes','Miércoles','Jueves','Viernes','Sábado'];
  const d = new Date(fechaStr + 'T00:00:00');
  return dias[d.getDay()];
}

function ruteoRangoSemanaLabel(lunesStr) {
  const l = new Date(lunesStr + 'T00:00:00');
  const dom = new Date(l); dom.setDate(l.getDate() + 6);
  const fmt = d => d.toLocaleDateString('es-CO', { day:'2-digit', month:'short' });
  return `${fmt(l)} – ${fmt(dom)}`;
}

// ---- UI helpers ----

function ruteoToast(msg, tipo = 'ok') {
  let t = document.getElementById('toast');
  if (!t) {
    t = document.createElement('div');
    t.id = 'toast';
    document.body.appendChild(t);
  }
  t.textContent = msg;
  t.className = tipo === 'err' ? 'err' : 'ok';
  requestAnimationFrame(() => t.classList.add('show'));
  clearTimeout(t._hideTimer);
  t._hideTimer = setTimeout(() => t.classList.remove('show'), 3500);
}

function ruteoErr(e) {
  ruteoToast(e && e.message ? e.message : 'Ocurrió un error.', 'err');
}

const RUTEO_TIPOS_CLIENTE = ['Constructor', 'Distribuidor', 'Arquitecto', 'Cliente final'];

function ruteoEscapeHtml(str) {
  if (str === null || str === undefined) return '';
  return String(str).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function ruteoEstadoBadge(estado) {
  const map = {
    programada: ['badge-blue', 'Programada'],
    visitada: ['badge-green', 'Visitada'],
    no_visitada: ['badge-red', 'No visitada'],
    cancelada: ['badge-gray', 'Cancelada'],
    reprogramada: ['badge-purple', 'Reprogramada'],
    vencida: ['badge-yellow', 'Vencida']
  };
  const [cls, label] = map[estado] || ['badge-gray', estado];
  return `<span class="badge ${cls}">${label}</span>`;
}

function ruteoColorCalendario(estadoEfectivo) {
  if (estadoEfectivo === 'visitada') return 'badge-green';
  if (['no_visitada', 'cancelada', 'reprogramada'].includes(estadoEfectivo)) return 'badge-yellow';
  if (estadoEfectivo === 'vencida') return 'badge-red';
  return 'badge-blue';
}

function ruteoSumarDias(fechaStr, n) {
  const d = new Date(fechaStr + 'T00:00:00');
  d.setDate(d.getDate() + n);
  return d.toISOString().slice(0, 10);
}

function ruteoOrigenBadge(origen) {
  const map = {
    planeacion: ['badge-gray', 'Planeada'],
    no_planeada: ['badge-orange', 'No planeada'],
    seguimiento: ['badge-purple', 'Seguimiento'],
    reprogramacion: ['badge-purple', 'Reprogramación']
  };
  const [cls, label] = map[origen] || ['badge-gray', origen];
  return `<span class="badge ${cls}">${label}</span>`;
}
