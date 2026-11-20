import { startSky } from './sky.js';
import { nowWords, placeLine } from './forecast-copy.js';

// On localhost, tools/serve_site.py forwards the request to the hosted API.
const LOCAL = ['localhost', '127.0.0.1'].includes(location.hostname);
const API = LOCAL ? '/v1/forecast' : 'https://api.zorja.app/v1/forecast';
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

requestAnimationFrame(() => document.body.classList.add('ready'));

// ---------- Sky ----------
const sky = startSky(document.getElementById('sky'), { reduceMotion: reduceMotion.matches });
reduceMotion.addEventListener('change', (e) => sky?.setPaused(e.matches));

// ---------- Reveals ----------
const revealer = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    e.target.classList.add('in');
    revealer.unobserve(e.target);
  }
}, { rootMargin: '0px 0px -12% 0px', threshold: 0.15 });
document.querySelectorAll('.reveal').forEach((el) => revealer.observe(el));

// ---------- Film ----------
// Plays once, muted, when mostly in view, and pauses out of view. With reduced
// motion, or when the browser refuses to autoplay, it waits behind its controls.
const film = document.getElementById('film');
if (film) {
  const offerControls = () => { film.controls = true; };
  film.addEventListener('ended', offerControls);
  if (reduceMotion.matches) offerControls();
  new IntersectionObserver(([e]) => {
    if (film.controls) { if (!e.isIntersecting) film.pause(); return; }
    if (e.isIntersecting) film.play().catch(offerControls);
    else film.pause();
  }, { threshold: 0.6 }).observe(film);
}

// ---------- Pinned phone ----------
const skyEl = document.querySelector('.sky');
const checkEl = document.getElementById('tonight');
const rig = document.querySelector('.phone-rig');
const story = document.querySelector('.story');
const slot = document.querySelector('.phone-slot');
const heroEnd = document.querySelector('.hero .fine');
const steps = [...document.querySelectorAll('.step')];
const shots = [...document.querySelectorAll('.shot')];
const lastHeading = steps.at(-1).querySelector('.chapter');
const EXIT_AT = 0.16; // share of the screen above the last heading when the phone starts to leave
let screen = 'now';
let stepScreen = 'now';

function showScreen(name) {
  if (name === screen) return;
  screen = name;
  for (const s of shots) s.classList.toggle('is-active', s.dataset.screen === name);
}

const stepWatcher = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    e.target.classList.add('in');
    e.target.querySelectorAll('.reveal').forEach((r) => r.classList.add('in'));
    stepScreen = e.target.dataset.screen;
  }
  schedule();
}, { rootMargin: '-42% 0px -42% 0px' });
steps.forEach((s) => stepWatcher.observe(s));

const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const mix = (a, b, t) => a + (b - a) * t;
const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const span = (t, a, b) => clamp((t - a) / (b - a));
const hero = document.querySelector('.hero');

let heroPhoneTop = 0; // document y of the phone's top in the hero
function measure() {
  const r = heroEnd.getBoundingClientRect();
  heroPhoneTop = Math.max(r.bottom + scrollY + 64, innerHeight * 0.68);
}

// Where the phone should be for the current scroll. The move has two phases, so it
// never cuts diagonally across the hero: first it lifts straight up into the middle
// of the screen while the hero fades, then it glides sideways into its column as the
// first chapter arrives. Small screens hide it (site.css) and show each screen inline.
function target() {
  const vw = innerWidth, vh = innerHeight;
  const H = rig.offsetHeight;
  const wide = vw >= 960;
  const y0 = scrollY;
  const storyTop = story.getBoundingClientRect().top + y0;
  const t = clamp(y0 / Math.max(storyTop, 1));
  if (!wide) return { x: 0, y: 0, exit: 0, s: 1, t, H };
  const lift = easeInOut(span(t, 0, 0.6));
  const glide = easeInOut(span(t, 0.22, 0.78));

  const sPinned = Math.min(1, (vh - 96) / H);
  const sHero = Math.min(1, (vh * 0.9) / H);
  const heroY = heroPhoneTop - y0 + (H * sHero) / 2 - vh / 2;
  const pinnedY = 0;
  const sr = slot.getBoundingClientRect();
  const pinnedX = sr.left + sr.width / 2 - vw / 2;
  // The phone leaves with the last chapter, once its heading has reached the top of the screen.
  const exit = Math.min(0, lastHeading.getBoundingClientRect().top - vh * EXIT_AT);
  return {
    x: mix(0, pinnedX, glide),
    y: mix(heroY, pinnedY, lift),
    exit,
    s: mix(sHero, sPinned, lift),
    t,
    H,
  };
}

// The rendered pose follows the target with a little inertia, so scrolling feels
// carried rather than bolted to the wheel. Reduce Motion follows it directly.
const pose = { x: 0, y: 0, s: 1 };
let last = 0, running = false, first = true;
function frame(now) {
  const goal = target();
  const dt = Math.min(0.05, (now - (last || now)) / 1000);
  last = now;
  const k = reduceMotion.matches || first ? 1 : 1 - Math.exp(-dt * 14);
  first = false;
  pose.x += (goal.x - pose.x) * k;
  pose.y += (goal.y - pose.y) * k;
  pose.s += (goal.s - pose.s) * k;
  // Leaving with the page follows the scroll directly: with inertia the phone trails
  // the words it leaves with and springs back after them when scrolling up.
  const y = pose.y + goal.exit;
  rig.style.transform = `translate(-50%, -50%) translate3d(${pose.x.toFixed(2)}px, ${y.toFixed(2)}px, 0) scale(${pose.s.toFixed(4)})`;
  rig.style.visibility = y + (goal.H * pose.s) / 2 < -innerHeight / 2 - 40 ? 'hidden' : 'visible';

  // The hero drifts up and fades as the phone takes over.
  const fade = span(goal.t, 0, 0.45);
  hero.style.opacity = String(1 - fade);
  hero.style.transform = reduceMotion.matches ? '' : `translate3d(0, ${(-fade * 60).toFixed(1)}px, 0)`;

  // The aurora leaves as the story begins, so the chapters sit on the dark sky, and
  // comes back for "What's Tonight Like Where You Are?".
  const away = span(goal.t, 0.3, 0.85);
  const back = span(innerHeight - checkEl.getBoundingClientRect().top, 0, innerHeight * 0.7);
  const skyOpacity = Math.max(1 - away, back);
  skyEl.style.opacity = skyOpacity.toFixed(3);
  sky?.setVisible(skyOpacity > 0.01);

  showScreen(goal.t < 0.5 ? 'now' : stepScreen);
  const settled = Math.abs(goal.x - pose.x) < 0.1 && Math.abs(goal.y - pose.y) < 0.1 && Math.abs(goal.s - pose.s) < 0.0005;
  if (settled) { running = false; last = 0; } else requestAnimationFrame(frame);
}
function schedule() {
  if (running) return;
  running = true;
  requestAnimationFrame(frame);
}
measure();
schedule();
addEventListener('scroll', schedule, { passive: true });
addEventListener('resize', () => { measure(); first = true; schedule(); });
document.fonts?.ready.then(() => { measure(); first = true; schedule(); });

// ---------- Tonight near you ----------
// Coordinates have two decimals (about 1 km), as in the app.
const PLACES = [
  { name: 'Tromsø', lat: 69.65, lon: 18.96, tz: 'Europe/Oslo' },
  { name: 'Abisko', lat: 68.35, lon: 18.83, tz: 'Europe/Stockholm' },
  { name: 'Rovaniemi', lat: 66.5, lon: 25.73, tz: 'Europe/Helsinki' },
  { name: 'Reykjavík', lat: 64.15, lon: -21.94, tz: 'Atlantic/Reykjavik' },
  { name: 'Fairbanks', lat: 64.84, lon: -147.72, tz: 'America/Anchorage' },
  { name: 'Yellowknife', lat: 62.45, lon: -114.37, tz: 'America/Edmonton' },
  { name: 'Edinburgh', lat: 55.95, lon: -3.19, tz: 'Europe/London' },
];
const FLOOR_MS = 60_000; // minimumRevalidationIntervalSeconds
const select = document.getElementById('place');
const locate = document.getElementById('locate');
const result = document.getElementById('result');
const out = {
  line: document.getElementById('result-line'),
  headline: document.getElementById('result-headline'),
  lead: document.getElementById('result-lead'),
  bottom: document.getElementById('result-bottom'),
  meta: document.getElementById('result-meta'),
};
for (const [i, p] of PLACES.entries()) select.add(new Option(p.name, String(i)));

const cache = new Map(); // key → { at, forecast }
let token = 0;

function phraseInto(el, ph) {
  el.textContent = '';
  if (!ph) return;
  const i = ph.emphasis ? ph.text.indexOf(ph.emphasis) : -1;
  if (i < 0) { el.textContent = ph.text; return; }
  const u = document.createElement('u');
  u.textContent = ph.emphasis;
  el.append(ph.text.slice(0, i), u, ph.text.slice(i + ph.emphasis.length));
}

function show({ line = '', headline, lead = '', bottom = null, meta = '', loading = false }) {
  const replay = result.hidden;
  result.hidden = false;
  result.classList.toggle('is-loading', loading);
  out.line.textContent = line;
  out.line.parentElement.hidden = !line;
  phraseInto(out.headline, headline);
  out.lead.textContent = lead;
  phraseInto(out.bottom, bottom);
  out.meta.textContent = meta;
  if (!replay && !loading && !reduceMotion.matches) {
    result.style.animation = 'none';
    void result.offsetWidth;
    result.style.animation = '';
  }
}

const hhmm = (d) => new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(d);

async function check(place) {
  const mine = ++token;
  const key = `${place.lat},${place.lon}`;
  const cached = cache.get(key);
  const now = Date.now();
  const fresh = cached && (now - cached.at < FLOOR_MS || new Date(cached.forecast.refreshAfter) > now);
  if (fresh) return render(place, cached.forecast);

  show({ line: place.label, headline: { text: 'Checking The Sky.' }, lead: `Looking at darkness, clouds and aurora over ${place.over}.`, loading: true });
  locate.setAttribute('aria-busy', 'true');
  try {
    const res = await fetch(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ latitude: place.lat, longitude: place.lon, timezone: place.tz }),
      cache: 'no-store',
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
    });
    if (mine !== token) return;
    if (res.status === 429 || res.status === 503) {
      const wait = Number(res.headers.get('Retry-After')) || 60;
      return show({ headline: { text: 'Can’t Check Right Now.', emphasis: 'Right Now' }, lead: `Zorja is busy. Try again at ${hhmm(new Date(Date.now() + wait * 1000))}.` });
    }
    if (res.status === 400) {
      // The request itself was refused, for example a browser time zone the API doesn't know.
      return show({ headline: { text: 'Can’t Check There.', emphasis: 'There' }, lead: 'Zorja couldn’t check the sky for this spot. Choose a place instead.' });
    }
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const forecast = await res.json();
    cache.set(key, { at: Date.now(), forecast });
    render(place, forecast);
  } catch (err) {
    if (mine !== token) return;
    if (!navigator.onLine) {
      show({ headline: { text: 'No Connection.', emphasis: 'No Connection' }, lead: 'You’re offline, so Zorja can’t check the sky. Try again when you’re back online.' });
    } else {
      show({ headline: { text: 'Can’t Check Right Now.', emphasis: 'Right Now' }, lead: 'Something went wrong on Zorja’s side. It isn’t your connection.' });
    }
  } finally {
    if (mine === token) locate.removeAttribute('aria-busy');
  }
}

function render(place, f) {
  const w = nowWords(f, new Date());
  show({
    line: placeLine(f, place.inLine) ?? place.label,
    headline: w.headline,
    lead: w.lead,
    bottom: w.bottom,
    meta: `Updated ${w.updated}, local time${place.mine ? '' : ` in ${place.name}`}.`,
  });
}

select.addEventListener('change', () => {
  const p = PLACES[Number(select.value)];
  if (p) check({ ...p, label: p.name, over: p.name, inLine: p.name });
});

locate.addEventListener('click', () => {
  const mine = ++token;
  if (!('geolocation' in navigator)) return cantFind();
  show({ headline: { text: 'Checking The Sky.' }, lead: 'Looking at darkness, clouds and aurora over your area.', loading: true });
  navigator.geolocation.getCurrentPosition((pos) => {
    if (mine !== token) return;
    const round = (v) => Math.round(v * 100) / 100;
    select.selectedIndex = 0;
    check({
      lat: round(pos.coords.latitude),
      lon: round(pos.coords.longitude),
      tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      name: 'your area', label: 'Your area', over: 'your area', inLine: 'your area', mine: true,
    });
  }, (err) => {
    if (mine !== token) return;
    if (err.code === err.PERMISSION_DENIED) {
      show({ headline: { text: 'Where Are You?', emphasis: 'Where' }, lead: 'Location is off for this page, so Zorja can’t check the sky where you are. Choose a place instead.' });
    } else cantFind();
  }, { enableHighAccuracy: false, timeout: 12_000, maximumAge: 10 * 60_000 });
});

function cantFind() {
  show({ headline: { text: 'Can’t Find You.', emphasis: 'Find You' }, lead: 'Your browser couldn’t work out where you are. Try again in a moment, or choose a place.' });
}
