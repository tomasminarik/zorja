// Zorja aurora sky: night sky with aurora curtains, stars, airglow and optional cloud.
// Port of the "Zorja Aurora Sky" Figma shader fill (WGSL, version 5c178938). The maths is
// kept line for line so the app matches the Figma screens; only the order of work changes.
// Two motion terms are the app's own (Figma's still frames don't show motion): rays that
// drift sideways along the curtain (`rayDrift`) and a slow brightness pulse that travels
// along it (`shimmer`). Both are zero in Figma's shader.
//
// The curtain terms that depend on x and time alone (wave, fine wave, ray height, fold)
// take about 70 % of the work, so `skyColumns` computes them once per pixel column and
// `skyFragment` reads them. `skyReferenceFragment` computes them per pixel, like the
// Figma shader; a test checks that both draw the same image. Driven by AuroraSkyRenderer.

#include <metal_stdlib>
using namespace metal;

/// Matches `AuroraSkyRenderer.Uniforms` in Swift.
struct SkyUniforms {
    float2 size;          // view size in points
    float time;           // seconds × speed
    float pixelScale;     // pixels per point, so stars and grain stay one device pixel wide
    float intensity;
    float cloudCover;
    float horizon;        // 0–1 from the top (Figma: 84 %)
    float seed;
    float curtainHeight;
    float starBrightness;
    float rayDrift;       // ray noise units per shader second
    float shimmer;        // depth of the travelling brightness pulse, 0 = none
};

namespace aurora {

float hash(float2 p) {
    float h = dot(p, float2(127.1, 311.7));
    return fract(sin(h) * 43758.5453);
}

float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

float fbm(float2 p) {
    float s = 0.0;
    float amp = 0.5;
    for (int k = 0; k < 5; k++) {
        s += amp * vnoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        amp *= 0.5;
    }
    return s;
}

/// The parts of one WGSL `curtain()` call that don't depend on y.
struct CurtainColumn {
    float wav;
    float fine;
    float hvar;
    float fold;
    float pulse;
};

CurtainColumn curtainColumn(float x, float freq, float height, float t, float seed, float shimmer) {
    CurtainColumn c;
    c.wav = fbm(float2(x * freq + seed, t * 0.04)) - 0.5;
    c.fine = fbm(float2(x * freq * 4.0 + seed * 3.0, t * 0.08)) - 0.5;
    c.hvar = height * (0.45 + 0.9 * fbm(float2(x * 1.2 + seed * 5.0, t * 0.03)));
    c.fold = 0.45 + 0.55 * fbm(float2(x * 1.1 + seed * 2.0, t * 0.03));
    // App only: patches of brighter curtain, about a third of the screen wide, that travel
    // along it and cross the screen in roughly 10 s.
    c.pulse = max(0.0, 1.0 + shimmer * 4.0 * (fbm(float2(x * 6.0 - t * 0.25 + seed * 4.0, t * 0.15)) - 0.5));
    return c;
}

// The rest of WGSL `curtain()`. x: aspect-corrected horizontal position, ux: 0–1
// horizontal position, y: 0 at the top. Returns (lower green body, upper red fringe).
float2 curtain(float x, float ux, float y, float base, float tilt, float arc, float amp,
               float t, float seed, float rayDensity, float rayDrift, CurtainColumn c) {
    float yb = base + tilt * (ux - 0.5) - arc * sin(3.14159 * ux) + amp * c.wav * 2.4 + 0.025 * c.fine;
    float d = yb - y;
    float warp = fbm(float2(x * 1.6 + seed, y * 2.4 + t * 0.02)) * 2.4;
    float rx = x * rayDensity + warp + t * rayDrift;
    float r1 = pow(vnoise(float2(rx, seed + t * 0.12)), 2.0);
    float r2 = pow(vnoise(float2(rx * 2.9, seed * 1.7 + t * 0.2)), 3.0);
    float rays = r1 * 0.9 + r2 * 0.6;
    float rayLen = c.hvar * (0.35 + 1.3 * r1);
    float below = exp(-max(-d, 0.0) * 140.0);
    float above = exp(-max(d, 0.0) / max(rayLen, 0.002));
    float prof = d >= 0.0 ? above : below;
    float body = prof * (0.18 + rays) * c.fold;
    float up = smoothstep(rayLen * 0.6, rayLen * 1.6, d) * exp(-max(d - rayLen * 1.6, 0.0) / max(rayLen, 0.002));
    float upper = up * r1 * c.fold;
    float edge = exp(-abs(d) * 180.0) * (0.3 + r1) * c.fold;
    return float2(body + edge * 0.7, upper) * c.pulse;
}

/// Column terms of both curtains, matching `SkyColumn` in the column buffer.
struct SkyColumn {
    CurtainColumn c1;
    CurtainColumn c2;
};

float2 skyUV(float2 position, constant SkyUniforms& u) {
    return position / max(u.size, float2(1.0));
}

/// Aspect-corrected x, as in WGSL `fs_main`.
float skyX(float2 uv, constant SkyUniforms& u) {
    float2 px = u.size * u.pixelScale;
    float asp = px.x / max(px.y, 1.0);
    return uv.x * asp;
}

float curtainScale(constant SkyUniforms& u) {
    return u.curtainHeight * (0.55 + u.intensity * 0.7);
}

SkyColumn skyColumn(float x, constant SkyUniforms& u) {
    float t = u.time;
    float ht = curtainScale(u);
    SkyColumn s;
    s.c1 = curtainColumn(x, 1.1, 0.16 * ht, t, u.seed, u.shimmer);
    s.c2 = curtainColumn(x * 1.25 + 5.0, 1.6, 0.07 * ht, t * 0.8, u.seed + 7.0, u.shimmer);
    return s;
}

/// WGSL `fs_main`, with the column terms passed in.
half4 shade(float2 position, constant SkyUniforms& u, SkyColumn col) {
    float2 uv = skyUV(position, u);
    float2 px = u.size * u.pixelScale;
    float t = u.time;
    float intensity = u.intensity;
    float horizon = u.horizon;
    float seed = u.seed;
    float x = skyX(uv, u);
    float y = uv.y;

    // Sky gradient, darkest at the top, with a faint green glow near the horizon.
    float hz = clamp(y / max(horizon, 0.05), 0.0, 1.0);
    float3 color = mix(float3(0.003, 0.006, 0.02), float3(0.028, 0.05, 0.095), pow(hz, 2.4));
    color += float3(0.01, 0.045, 0.03) * pow(hz, 7.0);

    // Stars on a 2.2-pixel grid, gently twinkling.
    float2 cell = floor(uv * px / 2.2);
    float sh = hash(cell + float2(seed, seed * 1.3));
    float tw = 0.75 + 0.25 * sin(t * 2.0 + sh * 40.0);
    float star = step(0.9965, sh) * (0.25 + 0.75 * hash(cell + 3.1)) * tw * u.starBrightness;
    float skyMask = smoothstep(horizon + 0.01, horizon - 0.05, y);

    // Two curtains: a tall main one and a lower, finer one.
    float2 c1 = curtain(x, uv.x, y, horizon - 0.27, -0.16, 0.06, 0.09, t, seed, 26.0, u.rayDrift, col.c1);
    float2 c2 = curtain(x * 1.25 + 5.0, uv.x, y, horizon - 0.11, 0.05, 0.02, 0.04, t * 0.8, seed + 7.0, 38.0, u.rayDrift, col.c2);
    float3 green = float3(0.22, 1.0, 0.52);
    float3 red = float3(0.62, 0.14, 0.40);
    float3 au = green * (c1.x + c2.x * 0.45);
    au += red * (c1.y * 0.55 + c2.y * 0.2) * smoothstep(0.55, 0.95, intensity);
    au *= (0.15 + intensity * 1.35);
    float glowY = horizon - 0.22;
    au += green * 0.05 * intensity * exp(-abs(y - glowY) * 6.0);
    au *= skyMask;

    // Optional cloud layer that hides aurora and stars.
    float cloudCover = u.cloudCover;
    float cn = fbm(float2(x * 2.1 + t * 0.015 + seed, y * 4.5));
    float cd = smoothstep(1.0 - cloudCover * 0.75 - 0.08, 1.0 - cloudCover * 0.75 + 0.2, cn) * step(0.01, cloudCover);
    float auL = min(1.0, (au.r + au.g + au.b) * 0.6);
    color += au * (1.0 - cd) + float3(star) * (1.0 - cd) * (1.0 - auL) * skyMask;
    float3 cc = float3(0.03, 0.04, 0.055) + green * 0.06 * intensity * cd;
    color = mix(color, cc, cd * 0.93);

    // Soft tone mapping and fine film grain.
    color = float3(1.0) - exp(-color * 1.7);
    float g = hash(uv * px + float2(fract(t), 0.0)) - 0.5;
    color += float3(g * 0.018);
    return half4(half3(clamp(color, float3(0.0), float3(1.0))), 1.0h);
}

} // namespace aurora

struct SkyVertexOut {
    float4 position [[position]];
};

/// One triangle that covers the whole target.
vertex SkyVertexOut skyVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    SkyVertexOut out;
    out.position = float4(p * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return out;
}

/// Pass 1: the column terms for every pixel column.
kernel void skyColumns(device aurora::SkyColumn* columns [[buffer(0)]],
                       constant SkyUniforms& u [[buffer(1)]],
                       constant uint& count [[buffer(2)]],
                       uint column [[thread_position_in_grid]]) {
    if (column >= count) return;
    float2 position = float2(float(column) + 0.5, 0.0) / u.pixelScale;
    float x = aurora::skyX(aurora::skyUV(position, u), u);
    columns[column] = aurora::skyColumn(x, u);
}

/// Pass 2: the sky, reading its column from pass 1.
fragment half4 skyFragment(SkyVertexOut in [[stage_in]],
                           constant SkyUniforms& u [[buffer(0)]],
                           device const aurora::SkyColumn* columns [[buffer(1)]]) {
    float2 position = in.position.xy / u.pixelScale;
    return aurora::shade(position, u, columns[uint(in.position.x)]);
}

/// The sky in one pass, every term per pixel as in Figma. Used by tests.
fragment half4 skyReferenceFragment(SkyVertexOut in [[stage_in]],
                                    constant SkyUniforms& u [[buffer(0)]]) {
    float2 position = in.position.xy / u.pixelScale;
    float x = aurora::skyX(aurora::skyUV(position, u), u);
    return aurora::shade(position, u, aurora::skyColumn(x, u));
}
