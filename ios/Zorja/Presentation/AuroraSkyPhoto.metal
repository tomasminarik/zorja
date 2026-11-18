// Zorja aurora sky, "photo" look: an exploration toward long-exposure aurora photographs.
// Broad, layered curtains whose rays fan out from a vanishing point below the horizon, a
// bright lime lower edge that turns green, teal and blue with height, a soft glow between
// the rays, faint magenta tops on strong nights, and a denser star field.
//
// Same uniforms as `AuroraSky.metal` (the classic look, kept as the fallback), so the
// renderer can switch between the two.

#include <metal_stdlib>
using namespace metal;

/// Matches `AuroraSkyRenderer.Uniforms` in Swift and `SkyUniforms` in AuroraSky.metal.
struct SkyUniforms {
    float2 size;
    float time;
    float pixelScale;
    float intensity;
    float cloudCover;
    float horizon;
    float seed;
    float curtainHeight;
    float starBrightness;
    float rayDrift;
    float shimmer;
};

namespace photo {

float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
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

float fbm(float2 p, int octaves) {
    float s = 0.0;
    float amp = 0.5;
    for (int k = 0; k < octaves; k++) {
        s += amp * vnoise(p);
        p = p * 2.03 + float2(1.7, 9.2);
        amp *= 0.5;
    }
    return s;
}

/// Shader seconds the curtains start at, so the first frame (also the still sky with Reduce
/// Motion) shows a full, varied curtain rather than a sparse one.
constant float startPhase = 20.0;

/// One curtain's shape. Heights are fractions of the view height, 0 at the top.
struct Curtain {
    float base;     // lower edge
    float tilt;     // edge rise from left to right
    float arc;      // edge bow; negative sags toward the horizon in the middle
    float amp;      // waviness of the edge
    float freq;     // waviness frequency
    float height;   // typical ray length
    float density;  // rays per radian seen from the vanishing point
    float bright;
    float seed;
    float xScale;   // the curtain's own x: x * xScale + xOffset
    float xOffset;
    float timeScale;
};

/// The three curtains: a low, finely rayed one at the back, the main arc, and tall faint
/// rays reaching for the top of the screen.
Curtain curtainAt(int i, constant SkyUniforms& u) {
    float hz = u.horizon;
    float seed = u.seed;
    switch (i) {
    case 0: return { hz - 0.18, 0.08, -0.05, 0.025, 3.0, 0.12, 130.0, 0.8, seed + 11.0, 1.0, 0.0, 0.9 };
    case 1: return { hz - 0.32, -0.08, -0.10, 0.035, 2.0, 0.24, 95.0, 1.0, seed, 1.0, 0.0, 1.0 };
    default: return { hz - 0.36, 0.08, -0.06, 0.04, 1.8, 0.42, 70.0, 0.6, seed + 23.0, 1.1, 3.0, 0.8 };
    }
}

/// Lower edge of a curtain at its own x (ux is 0–1 across the view).
float edgeY(float x, float ux, Curtain c, float t) {
    return c.base + c.tilt * (ux - 0.5) - c.arc * sin(3.14159 * ux)
        + c.amp * (fbm(float2(x * c.freq + c.seed, t * 0.035), 4) - 0.5) * 2.2;
}

/// The parts of a curtain that depend on x and time alone, computed once per pixel column.
struct CurtainColumn {
    float edge;
    float fold;
    float gain;
    float dense;    // 0 thin and see-through, 1 dense and bright
};

/// `x` is the view's aspect-corrected x, `ux` 0–1 across the view.
CurtainColumn curtainColumn(float x, float ux, Curtain c, constant SkyUniforms& u) {
    float t = (u.time + startPhase) * c.timeScale;
    float cx = x * c.xScale + c.xOffset;
    CurtainColumn col;
    col.edge = edgeY(cx, ux, c, t);
    // Where the edge runs steeply the curtain is seen edge-on and looks brighter (a fold).
    float asp = u.size.x / max(u.size.y, 1.0);
    float slope = (edgeY(cx + 0.008, ux + 0.008 / max(asp, 0.1), c, t) - col.edge) / 0.008;
    col.fold = 1.0 + 1.6 * smoothstep(0.15, 1.2, abs(slope));
    // Patches: a curtain is not equally bright along its length. Pulses travel along it.
    float patch = smoothstep(0.3, 0.72, fbm(float2(cx * 4.0 + c.seed * 3.0 - t * 0.02, t * 0.025), 4));
    float pulse = max(0.0, 1.0 + u.shimmer * 3.0 * (fbm(float2(cx * 5.0 - t * 0.22 + c.seed, t * 0.12), 3) - 0.5));
    // Large stretches where the curtain is dense (bright, yellow-green) or thin (faint, cyan).
    col.dense = smoothstep(0.25, 0.65, fbm(float2(cx * 1.3 + c.seed * 5.0 - t * 0.012, t * 0.02), 3));
    col.gain = patch * pulse * c.bright * mix(0.45, 1.2, col.dense);
    return col;
}

/// Light of one curtain at a point. `angle` is the direction from the vanishing point.
float3 curtain(float x, float y, float angle, Curtain c, CurtainColumn column, constant SkyUniforms& u) {
    float t = (u.time + startPhase) * c.timeScale;
    x = x * c.xScale + c.xOffset;
    float edge = column.edge;
    float d = edge - y;   // > 0 above the lower edge

    // Rays: noise across the fan, nudged by a slow warp so they bend with the curtain.
    float warp = fbm(float2(x * 1.4 + c.seed, y * 1.1 + t * 0.02), 3) * 1.6;
    float rx = angle * c.density + warp * 4.0 + t * u.rayDrift;
    float r1 = vnoise(float2(rx * 0.35, c.seed + t * 0.08));
    float r2 = vnoise(float2(rx, c.seed * 1.7 + t * 0.18));
    // Soft streaks: a few broad rays with gentler ones inside them. Dense stretches glow
    // more evenly; thin stretches show their rays more.
    float streaks = smoothstep(0.2, 1.0, r1) * (0.35 + 0.65 * smoothstep(0.1, 0.9, r2));
    float rays = mix(0.45, 0.62, column.dense) + mix(0.6, 0.42, column.dense) * streaks;

    float len = c.height * (0.55 + 0.9 * r1) * (0.55 + u.intensity * 0.6) * u.curtainHeight;
    float h = max(d, 0.0) / max(len, 0.004);   // height above the edge in ray lengths
    // A soft lower edge: the light fades out below it over a few percent of the height.
    float under = min(d, 0.0) / 0.02;
    float below = exp(-under * under);
    float body = d >= 0.0 ? exp(-h) * (0.6 + 0.5 * exp(-h * 3.0)) : below * 1.1;

    // Colour by altitude: lime at the edge, green, teal, then blue.
    float3 lime = float3(0.62, 1.0, 0.22);
    float3 green = float3(0.10, 1.0, 0.42);
    float3 teal = float3(0.02, 0.72, 0.78);
    float3 blue = float3(0.12, 0.26, 0.75);
    float3 col = mix(lime, green, smoothstep(0.0, 0.3, h));
    col = mix(col, teal, smoothstep(0.35, 1.2, h));
    col = mix(col, blue, smoothstep(1.3, 2.6, h));
    // Thin stretches lean cyan and blue; dense ones run yellow-green low down.
    col = mix(col, float3(0.05, 0.62, 0.88), (1.0 - column.dense) * 0.55 * smoothstep(-0.2, 0.6, h));
    // Bright yellow-green stays low on the screen, below the headline; higher up only
    // the fainter green and cyan of the curtains' upper parts shows.
    float low = smoothstep(0.36, 0.52, y);
    col = mix(col, float3(0.85, 1.0, 0.3), column.dense * exp(-h * 2.5) * 0.55 * low);
    col = mix(col, float3(0.05, 0.62, 0.88), (1.0 - low) * 0.35);
    float3 light = col * body * rays;
    // Soft light between the rays, so the curtain reads as a glowing sheet.
    float sheet = d >= 0.0 ? exp(-d / max(len * 1.6, 0.004)) : exp(d * 12.0);
    // Light scattered just below the lower edge, so a curtain never reads as a solid shape.
    light += mix(lime, green, 0.5) * 0.12 * exp(min(d, 0.0) * 18.0) * (0.5 + 0.5 * r1);
    light += mix(green, teal, smoothstep(0.0, 1.0, h)) * 0.2 * sheet * (0.6 + 0.4 * r1);
    // Magenta tops on strong nights.
    float top = smoothstep(0.9, 2.0, h) * exp(-max(h - 2.0, 0.0) * 0.6) * (0.4 + r1);
    light += float3(0.42, 0.06, 0.52) * top * 0.28 * smoothstep(0.4, 0.9, u.intensity);

    return light * column.fold * column.gain;
}

float3 stars(float2 uv, float2 px, float t, constant SkyUniforms& u) {
    float seed = u.seed;
    // Faint dust: a sparse grid of single pixels.
    float2 cell = floor(uv * px / 2.0);
    float sh = hash(cell + float2(seed, seed * 1.3));
    float tw = 0.7 + 0.3 * sin(t * 2.2 + sh * 40.0);
    float dust = step(0.9988, sh) * pow(hash(cell + 3.1), 2.0) * tw;
    // Brighter stars: one per larger cell at a random spot, slightly soft and tinted.
    float size = 9.0 * u.pixelScale;
    float2 p = uv * px / size;
    float2 c = floor(p);
    float pick = hash(c + float2(seed * 2.1, 7.7));
    float2 at = float2(hash(c + 1.3), hash(c + 5.9)) * 0.8 + 0.1;
    float r = length((p - c - at) * size) / u.pixelScale;
    float mag = pow(hash(c + 9.4), 3.0);
    float glow = exp(-r * r / (0.3 + mag * 1.0)) * step(0.96, pick) * (0.2 + 1.3 * mag);
    glow *= 0.75 + 0.25 * sin(t * 1.7 + pick * 60.0);
    float3 tint = mix(float3(0.75, 0.85, 1.0), float3(1.0, 0.92, 0.8), hash(c + 2.2));
    return (float3(dust * 0.6) + tint * glow) * u.starBrightness * 1.1;
}

/// Column terms of the three curtains, matching `PhotoColumn` in the column buffer.
struct SkyColumn {
    CurtainColumn c[3];
};

float2 skyUV(float2 position, constant SkyUniforms& u) {
    return position / max(u.size, float2(1.0));
}

float aspect(constant SkyUniforms& u) {
    float2 px = u.size * u.pixelScale;
    return px.x / max(px.y, 1.0);
}

SkyColumn skyColumn(float ux, constant SkyUniforms& u) {
    SkyColumn s;
    for (int i = 0; i < 3; i++) s.c[i] = curtainColumn(ux * aspect(u), ux, curtainAt(i, u), u);
    return s;
}

half4 shade(float2 position, constant SkyUniforms& u, SkyColumn columns) {
    float2 uv = position / max(u.size, float2(1.0));
    float2 px = u.size * u.pixelScale;
    float asp = px.x / max(px.y, 1.0);
    float x = uv.x * asp;
    float y = uv.y;
    float t = u.time;
    float horizon = u.horizon;
    float seed = u.seed;

    // Sky: deep navy at the top, lifting toward teal near the horizon.
    float hz = clamp(y / max(horizon, 0.05), 0.0, 1.0);
    float3 color = mix(float3(0.003, 0.008, 0.030), float3(0.012, 0.034, 0.078), pow(hz, 1.8));
    color += float3(0.01, 0.04, 0.04) * pow(hz, 8.0);
    // Faint violet haze high up on strong nights.
    float haze = fbm(float2(x * 1.3 + seed, y * 1.6 + t * 0.006), 3);
    color += float3(0.05, 0.010, 0.055) * smoothstep(0.42, 0.8, haze) * pow(1.0 - hz, 1.5) * smoothstep(0.4, 0.9, u.intensity);

    // Vanishing point below the horizon: rays fan out from it.
    float2 vp = float2(asp * 0.5, horizon + 0.9);
    float angle = atan2(x - vp.x, vp.y - y);

    float skyMask = smoothstep(horizon + 0.01, horizon - 0.04, y);
    float3 au = float3(0.0);
    for (int i = 0; i < 3; i++) au += curtain(x, y, angle, curtainAt(i, u), columns.c[i], u);
    // Diffuse aurora: a broad, patchy teal glow behind the curtains.
    float veil = fbm(float2(x * 1.6 + seed - t * 0.008, y * 1.2 + t * 0.01), 4);
    float veilOff = (y - (horizon - 0.38)) / 0.3;
    float veilBand = exp(-veilOff * veilOff);
    au += mix(float3(0.06, 0.55, 0.45), float3(0.12, 0.25, 0.55), smoothstep(0.3, 0.0, y)) * 0.22 * smoothstep(0.35, 0.75, veil) * veilBand;
    au *= 0.15 + u.intensity * 0.95;
    // More see-through toward the top of the screen, where the headline sits.
    au *= 0.6 + 0.4 * smoothstep(0.08, 0.5, y);
    // Green light scattered low in the sky.
    au += float3(0.10, 0.55, 0.30) * 0.03 * u.intensity * exp(-abs(y - (horizon - 0.12)) * 7.0);
    au *= skyMask;

    float3 st = stars(uv, px, t, u) * skyMask;

    // Optional cloud layer that hides aurora and stars.
    float cn = fbm(float2(x * 2.1 + t * 0.015 + seed, y * 4.5), 5);
    float cd = smoothstep(1.0 - u.cloudCover * 0.75 - 0.08, 1.0 - u.cloudCover * 0.75 + 0.2, cn) * step(0.01, u.cloudCover);
    float auL = min(1.0, dot(au, float3(0.3, 0.5, 0.2)));
    color += (au + st * (1.0 - 0.6 * auL)) * (1.0 - cd);
    float3 cc = float3(0.03, 0.04, 0.055) + float3(0.1, 0.5, 0.3) * 0.08 * u.intensity * cd;
    color = mix(color, cc, cd * 0.93);

    // A soft ceiling: light past `knee` rolls off toward `ceiling`, so the brightest
    // moments stay green instead of washing out to white over the text.
    float peak = max(color.r, max(color.g, color.b));
    float knee = 1.2;
    float ceiling = 1.75;
    if (peak > knee) {
        float over = peak - knee;
        color *= (knee + over / (1.0 + over / (ceiling - knee))) / peak;
    }

    // Tone mapping that keeps the lime edge saturated, then fine grain.
    color = float3(1.0) - exp(-color * 1.6);
    float g = hash(uv * px + float2(fract(t), 0.0)) - 0.5;
    color += float3(g * 0.016);
    return half4(half3(clamp(color, float3(0.0), float3(1.0))), 1.0h);
}

} // namespace photo

/// Pass 1: the column terms for every pixel column.
kernel void skyPhotoColumns(device photo::SkyColumn* columns [[buffer(0)]],
                            constant SkyUniforms& u [[buffer(1)]],
                            constant uint& count [[buffer(2)]],
                            uint column [[thread_position_in_grid]]) {
    if (column >= count) return;
    float ux = (float(column) + 0.5) / max(u.size.x * u.pixelScale, 1.0);
    columns[column] = photo::skyColumn(ux, u);
}

/// Pass 2: the sky, reading its column from pass 1. Uses `skyVertex` from AuroraSky.metal.
fragment half4 skyPhotoFragment(float4 position [[position]],
                                constant SkyUniforms& u [[buffer(0)]],
                                device const photo::SkyColumn* columns [[buffer(1)]]) {
    return photo::shade(position.xy / u.pixelScale, u, columns[uint(position.x)]);
}

/// The sky in one pass, every term per pixel. Used by tests.
fragment half4 skyPhotoReferenceFragment(float4 position [[position]],
                                         constant SkyUniforms& u [[buffer(0)]]) {
    float2 p = position.xy / u.pixelScale;
    return photo::shade(p, u, photo::skyColumn(photo::skyUV(p, u).x, u));
}
