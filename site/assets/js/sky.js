// Zorja aurora sky for the web: a line-for-line WebGL 2 port of the app's
// `ios/Zorja/Presentation/AuroraSkyPhoto.metal` (the "Photo" look, the app's default),
// with the same default parameters as `AuroraSkyParameters` and the same two passes:
// the curtain terms that depend on x and time alone are computed once per pixel column,
// then every pixel reads its column. If float render targets are missing, one pass
// computes everything per pixel (the shader's reference path).
//
// Keep in step with the Metal file: any change there is made here too.

const PARAMS = {
  intensity: 0.85,
  cloudCover: 0,
  horizon: 0.84,
  seed: 4,
  curtainHeight: 1,
  starBrightness: 0.3,
  speed: 1, // shader seconds per real second
  rayDrift: 0.5,
  shimmer: 0.35,
};
const FPS = 30; // SkyMotion.framesPerSecond
const MAX_PIXELS = 2_600_000; // keeps large, dense screens smooth

const COMMON = `#version 300 es
precision highp float;
precision highp int;
uniform vec2 u_size;          // view size in CSS pixels (the app's points)
uniform float u_time;
uniform float u_pixelScale;   // drawing pixels per CSS pixel
uniform float u_intensity;
uniform float u_cloudCover;
uniform float u_horizon;
uniform float u_seed;
uniform float u_curtainHeight;
uniform float u_starBrightness;
uniform float u_rayDrift;
uniform float u_shimmer;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 w = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

float fbm(vec2 p, int octaves) {
  float s = 0.0;
  float amp = 0.5;
  for (int k = 0; k < 5; k++) {
    if (k >= octaves) break;
    s += amp * vnoise(p);
    p = p * 2.03 + vec2(1.7, 9.2);
    amp *= 0.5;
  }
  return s;
}

const float startPhase = 20.0;

struct Curtain {
  float base; float tilt; float arc; float amp; float freq; float height;
  float density; float bright; float seed; float xScale; float xOffset; float timeScale;
};

Curtain curtainAt(int i) {
  float hz = u_horizon;
  float seed = u_seed;
  if (i == 0) return Curtain(hz - 0.18, 0.08, -0.05, 0.025, 3.0, 0.12, 130.0, 0.8, seed + 11.0, 1.0, 0.0, 0.9);
  if (i == 1) return Curtain(hz - 0.32, -0.08, -0.10, 0.035, 2.0, 0.24, 95.0, 1.0, seed, 1.0, 0.0, 1.0);
  return Curtain(hz - 0.36, 0.08, -0.06, 0.04, 1.8, 0.42, 70.0, 0.6, seed + 23.0, 1.1, 3.0, 0.8);
}

float edgeY(float x, float ux, Curtain c, float t) {
  return c.base + c.tilt * (ux - 0.5) - c.arc * sin(3.14159 * ux)
    + c.amp * (fbm(vec2(x * c.freq + c.seed, t * 0.035), 4) - 0.5) * 2.2;
}

// (edge, fold, gain, dense)
vec4 curtainColumn(float x, float ux, Curtain c) {
  float t = (u_time + startPhase) * c.timeScale;
  float cx = x * c.xScale + c.xOffset;
  float edge = edgeY(cx, ux, c, t);
  float asp = u_size.x / max(u_size.y, 1.0);
  float slope = (edgeY(cx + 0.008, ux + 0.008 / max(asp, 0.1), c, t) - edge) / 0.008;
  float fold = 1.0 + 1.6 * smoothstep(0.15, 1.2, abs(slope));
  float patchy = smoothstep(0.3, 0.72, fbm(vec2(cx * 4.0 + c.seed * 3.0 - t * 0.02, t * 0.025), 4));
  float pulse = max(0.0, 1.0 + u_shimmer * 3.0 * (fbm(vec2(cx * 5.0 - t * 0.22 + c.seed, t * 0.12), 3) - 0.5));
  float dense = smoothstep(0.25, 0.65, fbm(vec2(cx * 1.3 + c.seed * 5.0 - t * 0.012, t * 0.02), 3));
  float gain = patchy * pulse * c.bright * mix(0.45, 1.2, dense);
  return vec4(edge, fold, gain, dense);
}

float aspectPx() {
  vec2 px = u_size * u_pixelScale;
  return px.x / max(px.y, 1.0);
}
`;

const COLUMN_FS = COMMON + `
out vec4 outColor;
void main() {
  ivec2 fc = ivec2(gl_FragCoord.xy);
  float ux = (float(fc.x) + 0.5) / max(u_size.x * u_pixelScale, 1.0);
  outColor = curtainColumn(ux * aspectPx(), ux, curtainAt(fc.y));
}
`;

const SHADE = `
vec3 curtain(float x, float y, float angle, Curtain c, vec4 column) {
  float colEdge = column.x, colFold = column.y, colGain = column.z, colDense = column.w;
  float t = (u_time + startPhase) * c.timeScale;
  x = x * c.xScale + c.xOffset;
  float d = colEdge - y;

  float warp = fbm(vec2(x * 1.4 + c.seed, y * 1.1 + t * 0.02), 3) * 1.6;
  float rx = angle * c.density + warp * 4.0 + t * u_rayDrift;
  float r1 = vnoise(vec2(rx * 0.35, c.seed + t * 0.08));
  float r2 = vnoise(vec2(rx, c.seed * 1.7 + t * 0.18));
  float streaks = smoothstep(0.2, 1.0, r1) * (0.35 + 0.65 * smoothstep(0.1, 0.9, r2));
  float rays = mix(0.45, 0.62, colDense) + mix(0.6, 0.42, colDense) * streaks;

  float len = c.height * (0.55 + 0.9 * r1) * (0.55 + u_intensity * 0.6) * u_curtainHeight;
  float h = max(d, 0.0) / max(len, 0.004);
  float under = min(d, 0.0) / 0.02;
  float below = exp(-under * under);
  float body = d >= 0.0 ? exp(-h) * (0.6 + 0.5 * exp(-h * 3.0)) : below * 1.1;

  vec3 lime = vec3(0.62, 1.0, 0.22);
  vec3 green = vec3(0.10, 1.0, 0.42);
  vec3 teal = vec3(0.02, 0.72, 0.78);
  vec3 blue = vec3(0.12, 0.26, 0.75);
  vec3 col = mix(lime, green, smoothstep(0.0, 0.3, h));
  col = mix(col, teal, smoothstep(0.35, 1.2, h));
  col = mix(col, blue, smoothstep(1.3, 2.6, h));
  col = mix(col, vec3(0.05, 0.62, 0.88), (1.0 - colDense) * 0.55 * smoothstep(-0.2, 0.6, h));
  float low = smoothstep(0.36, 0.52, y);
  col = mix(col, vec3(0.85, 1.0, 0.3), colDense * exp(-h * 2.5) * 0.55 * low);
  col = mix(col, vec3(0.05, 0.62, 0.88), (1.0 - low) * 0.35);
  vec3 light = col * body * rays;
  float sheet = d >= 0.0 ? exp(-d / max(len * 1.6, 0.004)) : exp(d * 12.0);
  light += mix(lime, green, 0.5) * 0.12 * exp(min(d, 0.0) * 18.0) * (0.5 + 0.5 * r1);
  light += mix(green, teal, smoothstep(0.0, 1.0, h)) * 0.2 * sheet * (0.6 + 0.4 * r1);
  float top = smoothstep(0.9, 2.0, h) * exp(-max(h - 2.0, 0.0) * 0.6) * (0.4 + r1);
  light += vec3(0.42, 0.06, 0.52) * top * 0.28 * smoothstep(0.4, 0.9, u_intensity);

  return light * colFold * colGain;
}

vec3 stars(vec2 uv, vec2 px, float t) {
  float seed = u_seed;
  vec2 cell = floor(uv * px / 2.0);
  float sh = hash(cell + vec2(seed, seed * 1.3));
  float tw = 0.7 + 0.3 * sin(t * 2.2 + sh * 40.0);
  float dust = step(0.9988, sh) * pow(hash(cell + 3.1), 2.0) * tw;
  float size = 9.0 * u_pixelScale;
  vec2 p = uv * px / size;
  vec2 c = floor(p);
  float pick = hash(c + vec2(seed * 2.1, 7.7));
  vec2 at = vec2(hash(c + 1.3), hash(c + 5.9)) * 0.8 + 0.1;
  float r = length((p - c - at) * size) / u_pixelScale;
  float mag = pow(hash(c + 9.4), 3.0);
  float glow = exp(-r * r / (0.3 + mag * 1.0)) * step(0.96, pick) * (0.2 + 1.3 * mag);
  glow *= 0.75 + 0.25 * sin(t * 1.7 + pick * 60.0);
  vec3 tint = mix(vec3(0.75, 0.85, 1.0), vec3(1.0, 0.92, 0.8), hash(c + 2.2));
  return (vec3(dust * 0.6) + tint * glow) * u_starBrightness * 1.1;
}

vec4 shade(vec2 position, vec4 c0, vec4 c1, vec4 c2) {
  vec2 uv = position / max(u_size, vec2(1.0));
  vec2 px = u_size * u_pixelScale;
  float asp = px.x / max(px.y, 1.0);
  float x = uv.x * asp;
  float y = uv.y;
  float t = u_time;
  float horizon = u_horizon;
  float seed = u_seed;

  float hz = clamp(y / max(horizon, 0.05), 0.0, 1.0);
  vec3 color = mix(vec3(0.003, 0.008, 0.030), vec3(0.012, 0.034, 0.078), pow(hz, 1.8));
  color += vec3(0.01, 0.04, 0.04) * pow(hz, 8.0);
  float haze = fbm(vec2(x * 1.3 + seed, y * 1.6 + t * 0.006), 3);
  color += vec3(0.05, 0.010, 0.055) * smoothstep(0.42, 0.8, haze) * pow(1.0 - hz, 1.5) * smoothstep(0.4, 0.9, u_intensity);

  vec2 vp = vec2(asp * 0.5, horizon + 0.9);
  float angle = atan(x - vp.x, vp.y - y);

  float skyMask = smoothstep(horizon + 0.01, horizon - 0.04, y);
  vec3 au = vec3(0.0);
  au += curtain(x, y, angle, curtainAt(0), c0);
  au += curtain(x, y, angle, curtainAt(1), c1);
  au += curtain(x, y, angle, curtainAt(2), c2);
  float veil = fbm(vec2(x * 1.6 + seed - t * 0.008, y * 1.2 + t * 0.01), 4);
  float veilOff = (y - (horizon - 0.38)) / 0.3;
  float veilBand = exp(-veilOff * veilOff);
  au += mix(vec3(0.06, 0.55, 0.45), vec3(0.12, 0.25, 0.55), smoothstep(0.3, 0.0, y)) * 0.22 * smoothstep(0.35, 0.75, veil) * veilBand;
  au *= 0.15 + u_intensity * 0.95;
  au *= 0.6 + 0.4 * smoothstep(0.08, 0.5, y);
  au += vec3(0.10, 0.55, 0.30) * 0.03 * u_intensity * exp(-abs(y - (horizon - 0.12)) * 7.0);
  au *= skyMask;

  vec3 st = stars(uv, px, t) * skyMask;

  float cd = 0.0;
  if (u_cloudCover >= 0.01) {
    float cn = fbm(vec2(x * 2.1 + t * 0.015 + seed, y * 4.5), 5);
    cd = smoothstep(1.0 - u_cloudCover * 0.75 - 0.08, 1.0 - u_cloudCover * 0.75 + 0.2, cn);
  }
  float auL = min(1.0, dot(au, vec3(0.3, 0.5, 0.2)));
  color += (au + st * (1.0 - 0.6 * auL)) * (1.0 - cd);
  vec3 cc = vec3(0.03, 0.04, 0.055) + vec3(0.1, 0.5, 0.3) * 0.08 * u_intensity * cd;
  color = mix(color, cc, cd * 0.93);

  float peak = max(color.r, max(color.g, color.b));
  float knee = 1.2;
  float ceiling = 1.75;
  if (peak > knee) {
    float over = peak - knee;
    color *= (knee + over / (1.0 + over / (ceiling - knee))) / peak;
  }

  color = vec3(1.0) - exp(-color * 1.6);
  float g = hash(uv * px + vec2(fract(t), 0.0)) - 0.5;
  color += vec3(g * 0.016);
  return vec4(clamp(color, vec3(0.0), vec3(1.0)), 1.0);
}
`;

const SKY_FS = COMMON + SHADE + `
uniform sampler2D u_columns;
uniform vec2 u_resolution;
out vec4 outColor;
void main() {
  vec2 position = vec2(gl_FragCoord.x, u_resolution.y - gl_FragCoord.y) / u_pixelScale;
  int cx = int(gl_FragCoord.x);
  outColor = shade(position,
    texelFetch(u_columns, ivec2(cx, 0), 0),
    texelFetch(u_columns, ivec2(cx, 1), 0),
    texelFetch(u_columns, ivec2(cx, 2), 0));
}
`;

const REFERENCE_FS = COMMON + SHADE + `
uniform vec2 u_resolution;
out vec4 outColor;
void main() {
  vec2 position = vec2(gl_FragCoord.x, u_resolution.y - gl_FragCoord.y) / u_pixelScale;
  float ux = position.x / max(u_size.x, 1.0);
  float x = ux * aspectPx();
  outColor = shade(position,
    curtainColumn(x, ux, curtainAt(0)),
    curtainColumn(x, ux, curtainAt(1)),
    curtainColumn(x, ux, curtainAt(2)));
}
`;

const VS = `#version 300 es
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
`;

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}

function program(gl, fs) {
  const p = gl.createProgram();
  gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, VS));
  gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  const loc = {};
  const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < n; i++) {
    const name = gl.getActiveUniform(p, i).name;
    loc[name] = gl.getUniformLocation(p, name);
  }
  return { p, loc };
}

/**
 * Starts the sky on `canvas`. Returns a controller, or null when WebGL 2 is missing
 * (the page then keeps its plain bg/base background).
 */
export function startSky(canvas, { reduceMotion = false } = {}) {
  const gl = canvas.getContext('webgl2', { alpha: false, antialias: false, depth: false, stencil: false, powerPreference: 'high-performance', preserveDrawingBuffer: false });
  if (!gl) return null;

  const twoPass = !!gl.getExtension('EXT_color_buffer_float');
  let sky, columns, tex, fbo;
  try {
    sky = program(gl, twoPass ? SKY_FS : REFERENCE_FS);
    if (twoPass) columns = program(gl, COLUMN_FS);
  } catch (e) {
    console.warn('Sky shader failed', e);
    return null;
  }
  gl.bindVertexArray(gl.createVertexArray());

  if (twoPass) {
    tex = gl.createTexture();
    fbo = gl.createFramebuffer();
  }

  let cssW = 0, cssH = 0, scale = 1, colWidth = 0;
  function resize() {
    const rect = canvas.getBoundingClientRect();
    cssW = Math.max(1, rect.width);
    cssH = Math.max(1, rect.height);
    scale = Math.min(window.devicePixelRatio || 1, 2);
    if (cssW * cssH * scale * scale > MAX_PIXELS) scale = Math.sqrt(MAX_PIXELS / (cssW * cssH));
    const w = Math.round(cssW * scale), h = Math.round(cssH * scale);
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    scale = w / cssW;
    if (twoPass && colWidth !== w) {
      colWidth = w;
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA32F, w, 3, 0, gl.RGBA, gl.FLOAT, null);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    }
  }

  function setCommon(loc, time) {
    gl.uniform2f(loc.u_size, cssW, cssH);
    gl.uniform1f(loc.u_time, time);
    gl.uniform1f(loc.u_pixelScale, scale);
    gl.uniform1f(loc.u_intensity, PARAMS.intensity);
    gl.uniform1f(loc.u_cloudCover, PARAMS.cloudCover);
    gl.uniform1f(loc.u_horizon, PARAMS.horizon);
    gl.uniform1f(loc.u_seed, PARAMS.seed);
    gl.uniform1f(loc.u_curtainHeight, PARAMS.curtainHeight);
    gl.uniform1f(loc.u_starBrightness, PARAMS.starBrightness);
    gl.uniform1f(loc.u_rayDrift, PARAMS.rayDrift);
    gl.uniform1f(loc.u_shimmer, PARAMS.shimmer);
  }

  function draw(time) {
    if (twoPass) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.viewport(0, 0, canvas.width, 3);
      gl.useProgram(columns.p);
      setCommon(columns.loc, time);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    }
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.useProgram(sky.p);
    setCommon(sky.loc, time);
    gl.uniform2f(sky.loc.u_resolution, canvas.width, canvas.height);
    if (twoPass) {
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.uniform1i(sky.loc.u_columns, 0);
    }
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  // SkyClock: time only advances while the sky runs, so it carries on where it stopped.
  let accumulated = 0, resumedAt = null, raf = 0, last = 0, visible = true, paused = reduceMotion;
  const now = () => performance.now() / 1000;
  const elapsed = () => accumulated + (resumedAt == null ? 0 : now() - resumedAt);
  function setRunning(run) {
    if (run && resumedAt == null) resumedAt = now();
    else if (!run && resumedAt != null) { accumulated += now() - resumedAt; resumedAt = null; }
  }

  function frame(ms) {
    raf = requestAnimationFrame(frame);
    if (ms - last < 1000 / FPS - 2) return;
    last = ms;
    draw(elapsed() * PARAMS.speed);
  }

  function update() {
    const run = visible && !paused && !document.hidden;
    setRunning(run);
    cancelAnimationFrame(raf);
    if (run) raf = requestAnimationFrame(frame);
    else draw(elapsed() * PARAMS.speed);
  }

  resize();
  draw(0);
  update();

  const ro = new ResizeObserver(() => { resize(); draw(elapsed() * PARAMS.speed); });
  ro.observe(canvas);
  document.addEventListener('visibilitychange', update);
  canvas.addEventListener('webglcontextlost', (e) => { e.preventDefault(); cancelAnimationFrame(raf); });

  return {
    twoPass,
    /** Stop drawing while the sky is off screen or fully covered. */
    setVisible(v) { if (v !== visible) { visible = v; update(); } },
    setPaused(p) { if (p !== paused) { paused = p; update(); } },
  };
}
