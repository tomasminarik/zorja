// Support and privacy pages: the same sky across the top, the hero rise and scroll reveals.
import { startSky } from './sky.js';

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
requestAnimationFrame(() => document.body.classList.add('ready'));

const canvas = document.getElementById('sky');
const sky = startSky(canvas, { reduceMotion: reduceMotion.matches });
reduceMotion.addEventListener('change', (e) => sky?.setPaused(e.matches));
if (sky) {
  // The sky sits at the top of the page; stop drawing once it has scrolled away.
  new IntersectionObserver(([e]) => sky.setVisible(e.isIntersecting)).observe(canvas);
}

const io = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    e.target.classList.add('in');
    io.unobserve(e.target);
  }
}, { rootMargin: '0px 0px -8% 0px' });
document.querySelectorAll('.reveal').forEach((el, i) => { el.style.setProperty('--i', String(Math.min(i, 6))); io.observe(el); });
