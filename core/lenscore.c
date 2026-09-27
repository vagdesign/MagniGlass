/*
 * MagniGlass lens renderer. See lenscore.h.
 *
 * The look is built from simple optics rather than painted highlights:
 *  - a biconvex lens: the pointer area magnified, with pincushion distortion growing
 *    towards the rim, a strongly bent band at the ground edge of the glass and lateral
 *    colour fringes (blue bends more than red)
 *  - reflections of a studio (sky gradient, two soft boxes) on the front surface and,
 *    mirrored, on the back surface, weighted by Fresnel, so the highlights sit where a
 *    real curved glass puts them
 *  - a chrome rim and a turned chrome grip (ferrule, collar, knurled body, domed end cap)
 *    shaded as mirrors of the same studio
 *  - a soft shadow: dark under the metal, faint under the glass
 * Everything except the glass contents is drawn once per size; per frame only the
 * refraction table is applied (bilinear, per colour channel).
 */
#include "lenscore.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int32_t rx, ry, gx, gy, bx, by; /* source offsets from the pointer, 1/256 px */
    uint16_t tr, tg, tb;            /* transmission, 0..256 */
    uint8_t ar, ag, ab;             /* reflection (screen-blended), 0..255 */
    uint8_t inside;
} GlassPx;

struct LensCtx {
    int diameter, flags;
    float zoom, R, rim_w, ro;
    int W, H, cxi, cyi;
    float cx, cy; /* lens centre in image coordinates (pixel centre) */
    float hx, hy; /* grip direction */
    uint32_t *stat;
    int gx0, gy0, gw, gh;
    GlassPx *lut;
    int src_radius;
};

typedef struct { float x, y, z; } V3;

static inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline float sat(float v) { return clampf(v, 0.f, 1.f); }
static inline float smooth(float e0, float e1, float x) {
    float t = sat((x - e0) / (e1 - e0));
    return t * t * (3.f - 2.f * t);
}
static inline float mixf(float a, float b, float t) { return a + (b - a) * t; }
static inline V3 v3(float x, float y, float z) { V3 v = {x, y, z}; return v; }
static inline float dot3(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static inline V3 norm3(V3 a) {
    float l = sqrtf(dot3(a, a));
    return l > 0 ? v3(a.x / l, a.y / l, a.z / l) : v3(0, 0, 1);
}
/* Direction a ray from the eye (looking into the screen, -z) leaves after hitting normal n. */
static inline V3 reflect_view(V3 n) {
    return v3(2.f * n.z * n.x, 2.f * n.z * n.y, 2.f * n.z * n.z - 1.f);
}

/* ------------------------------------------------------------------------ */
/* Studio environment (HDR, linear). Screen up is -y, the viewer is +z.      */
/* ------------------------------------------------------------------------ */

static V3 L_KEY, L_FILL, L_SUN;
static V3 KEY_U, KEY_V, FILL_U, FILL_V;
static int env_ready;

static V3 cross3(V3 a, V3 b) { return v3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }

static void env_init(void) {
    if (env_ready) return;
    L_KEY = norm3(v3(-0.50f, -0.62f, 0.60f));  /* window / large soft box, upper left */
    L_FILL = norm3(v3(0.78f, 0.10f, 0.62f));   /* narrow strip light on the right */
    L_SUN = norm3(v3(-0.40f, -0.55f, 0.73f));  /* small hard light for the sparkle */
    KEY_U = norm3(cross3(v3(0, 1, 0), L_KEY)); KEY_V = cross3(L_KEY, KEY_U);
    FILL_U = norm3(cross3(v3(0, 1, 0), L_FILL)); FILL_V = cross3(L_FILL, FILL_U);
    env_ready = 1;
}

/* Soft-edged rectangle of half sizes (hu, hv) radians around direction l. */
static float softbox(V3 r, V3 l, V3 u, V3 v, float hu, float hv, float soft) {
    float d = dot3(r, l);
    if (d <= 0.f) return 0.f;
    float a = dot3(r, u) / d, b = dot3(r, v) / d;
    return (1.f - smooth(hu - soft, hu + soft, fabsf(a))) * (1.f - smooth(hv - soft, hv + soft, fabsf(b)));
}

static V3 env(V3 r, float boxes) {
    /* Horizon tilted a little towards the viewer so faces looking at us see the sky. */
    float e = -r.y * 0.85f + r.z * 0.30f - 0.10f;
    float sky = 0.72f + 0.38f * sat(e);
    float ground = 0.05f + 0.30f * smooth(0.02f, 0.80f, -e);
    float t = smooth(-0.03f, 0.02f, e);
    float lum = mixf(ground, sky, t);
    /* sky slightly cool, ground warm */
    V3 c = v3(lum * mixf(1.00f, 0.92f, t), lum * mixf(0.97f, 0.96f, t), lum * mixf(0.92f, 1.03f, t));
    /* darker room walls to the far left/right give the chrome its contrast bands */
    float wall = smooth(0.45f, 0.80f, fabsf(r.x)) * (1.f - t * 0.5f);
    float wk = 1.f - 0.65f * wall;
    c.x *= wk; c.y *= wk; c.z *= wk;
    /* window with a mullion: two panes */
    float key = softbox(r, L_KEY, KEY_U, KEY_V, 0.30f, 0.20f, 0.05f);
    float mull = 1.f - 0.85f * (1.f - smooth(0.012f, 0.03f, fabsf(dot3(r, KEY_U) / fmaxf(1e-3f, dot3(r, L_KEY)))));
    float fill = softbox(r, L_FILL, FILL_U, FILL_V, 0.05f, 0.35f, 0.04f);
    float add = (key * mull * 6.0f + fill * 2.2f) * boxes;
    c.x += add; c.y += add; c.z += add * 0.98f;
    return c;
}

/* Polished chrome: a slightly warm silver mirror of the studio plus a hard glint. */
static V3 chrome(V3 n, float ao) {
    V3 r = reflect_view(n);
    V3 e = env(r, 0.55f);
    float spec = powf(sat(dot3(r, L_SUN)), 180.f) * 2.5f;
    float k = 0.86f * ao;
    return v3(sat(e.x * k * 0.99f + spec), sat(e.y * k * 0.99f + spec), sat(e.z * k * 1.02f + spec));
}

/* ------------------------------------------------------------------------ */
/* Grip profile: radius of the turned handle at distance s from the centre.  */
/* ------------------------------------------------------------------------ */

typedef struct {
    float s0, s_neck, s_col, s_grip, s_end, s_cap;
    float r_ferrule, r_neck, r_col, r_grip, r_cap;
    float groove[4], groove_w;
    float knurl0, knurl1, knurl_p;
} Grip;

static void grip_init(Grip *g, float D, float R, float ro, float rim_w) {
    g->s0 = R + rim_w * 0.35f;
    g->s_neck = ro + 0.035f * D;
    g->s_col = ro + 0.13f * D;
    g->s_grip = g->s_col + 0.065f * D;
    g->s_end = g->s_grip + 0.86f * D;
    g->s_cap = g->s_end + 0.045f * D;
    g->r_ferrule = fmaxf(4.f, 0.072f * D);
    g->r_neck = fmaxf(2.5f, 0.034f * D);
    g->r_col = fmaxf(4.f, 0.066f * D);
    g->r_grip = fmaxf(3.5f, 0.056f * D);
    g->r_cap = g->r_grip * 1.05f;
    g->groove_w = fmaxf(1.2f, 0.011f * D);
    g->groove[0] = g->s_grip + 0.045f * D;
    g->groove[1] = g->s_grip + 0.075f * D;
    g->groove[2] = g->s_end - 0.075f * D;
    g->groove[3] = g->s_end - 0.045f * D;
    g->knurl0 = g->s_grip + 0.12f * D;
    g->knurl1 = g->s_end - 0.12f * D;
    g->knurl_p = fmaxf(3.f, 0.022f * D);
}

/* Rounded step: 1 in the middle of [a, b], falling to 0 at both ends over width w. */
static float rounded(float s, float a, float b, float w) {
    float e = fminf(s - a, b - s) / w;
    if (e <= 0.f) return 0.f;
    if (e >= 1.f) return 1.f;
    return sqrtf(e * (2.f - e));
}

static float grip_radius(const Grip *g, float s) {
    if (s < g->s0 || s > g->s_cap) return 0.f;
    if (s < g->s_col) {
        /* ferrule flaring into the rim, then a thin neck */
        float f = 1.f - smooth(g->s0, g->s_neck, s);
        float r = g->r_neck + (g->r_ferrule - g->r_neck) * f * f;
        /* tiny bead where the neck meets the collar */
        return r;
    }
    if (s < g->s_grip) {
        float c = rounded(s, g->s_col, g->s_grip, (g->s_grip - g->s_col) * 0.35f);
        return fmaxf(g->r_grip * 0.92f, g->r_neck + (g->r_col - g->r_neck) * c);
    }
    if (s < g->s_end) {
        float u = (s - g->s_grip) / (g->s_end - g->s_grip);
        /* gently swelling body, a little thicker towards the end */
        float r = g->r_grip * (1.f + 0.07f * u + 0.05f * sinf(u * 3.14159f));
        for (int i = 0; i < 4; i++) {
            float d = fabsf(s - g->groove[i]) / g->groove_w;
            if (d < 1.f) r *= 1.f - 0.10f * (1.f - d);
        }
        /* soft shoulders at both ends of the body */
        r *= 0.94f + 0.06f * rounded(s, g->s_grip, g->s_end, 0.02f * (g->s_end - g->s_grip) + 1.f);
        return r;
    }
    /* domed end cap */
    float u = (s - g->s_end) / (g->s_cap - g->s_end);
    float body_end = g->r_grip * 1.07f;
    return body_end * sqrtf(sat(1.f - u * u)) * (u < 0.15f ? 1.f : 0.98f);
}

/* ------------------------------------------------------------------------ */

static void box_blur(float *a, float *tmp, int W, int H, int r) {
    if (r < 1) return;
    float inv = 1.f / (2 * r + 1);
    for (int y = 0; y < H; y++) {
        float *row = a + (size_t)y * W, *out = tmp + (size_t)y * W;
        float acc = 0;
        for (int x = -r; x <= r; x++) acc += row[x < 0 ? 0 : (x >= W ? W - 1 : x)];
        for (int x = 0; x < W; x++) {
            out[x] = acc * inv;
            int xa = x + r + 1, xs = x - r;
            acc += row[xa >= W ? W - 1 : xa] - row[xs < 0 ? 0 : xs];
        }
    }
    for (int x = 0; x < W; x++) {
        float acc = 0;
        for (int y = -r; y <= r; y++) acc += tmp[(size_t)(y < 0 ? 0 : (y >= H ? H - 1 : y)) * W + x];
        for (int y = 0; y < H; y++) {
            a[(size_t)y * W + x] = acc * inv;
            int ya = y + r + 1, ys = y - r;
            acc += tmp[(size_t)(ya >= H ? H - 1 : ya) * W + x] - tmp[(size_t)(ys < 0 ? 0 : ys) * W + x];
        }
    }
}

static inline uint32_t pack(float r, float g, float b, float a) {
    /* premultiplied inputs */
    uint32_t A = (uint32_t)(sat(a) * 255.f + 0.5f);
    uint32_t Rr = (uint32_t)(sat(r) * 255.f + 0.5f), G = (uint32_t)(sat(g) * 255.f + 0.5f), B = (uint32_t)(sat(b) * 255.f + 0.5f);
    if (Rr > A) Rr = A;
    if (G > A) G = A;
    if (B > A) B = A;
    return (A << 24) | (Rr << 16) | (G << 8) | B;
}

/* Rim cross-section: radial component of the normal across the ring (u: 0 inner, 1 outer). */
static float rim_normal_r(float u) {
    float x = 2.f * u - 1.f;
    float n = x * powf(fabsf(x), 0.55f) * 0.96f; /* rounded, fairly flat on top */
    /* inner bevel stepping down to the glass */
    float lip = 1.f - smooth(0.10f, 0.20f, u);
    n = mixf(n, -0.72f, lip);
    /* narrow polished ridge just inside the bevel */
    float ridge = rounded(u, 0.20f, 0.27f, 0.03f);
    n = mixf(n, -0.25f, ridge * 0.6f);
    return clampf(n, -0.985f, 0.985f);
}

static void build_static(LensCtx *c) {
    const int W = c->W, H = c->H;
    const float D = (float)c->diameter, R = c->R, ro = c->ro;
    const float rin = R - 1.f; /* rim starts 1px inside the glass so there is never a gap */
    Grip g;
    grip_init(&g, D, R, ro, c->rim_w);
    const float px = -c->hy, py = c->hx; /* perpendicular to the grip */
    const float gmax = fmaxf(g.r_ferrule, fmaxf(g.r_col, g.r_grip * 1.2f));

    float *mask = (float *)calloc((size_t)W * H, sizeof(float));
    float *tmp = (float *)malloc((size_t)W * H * sizeof(float));
    float *col = (float *)calloc((size_t)W * H * 4, sizeof(float)); /* premultiplied RGBA of metal */

    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            float dx = x + 0.5f - c->cx, dy = y + 0.5f - c->cy;
            float r = sqrtf(dx * dx + dy * dy);
            size_t i = (size_t)y * W + x;
            float out_r = 0, out_g = 0, out_b = 0, out_a = 0;

            /* grip (behind the rim) */
            float s = dx * c->hx + dy * c->hy;
            float t = dx * px + dy * py;
            float rad = fabsf(t) < gmax + 1.f ? grip_radius(&g, s) : 0.f;
            float cov_h = 0;
            if (rad > 0.f && fabsf(t) < rad + 1.f) {
                cov_h = sat(rad - fabsf(t) + 0.5f);
                float nt = clampf(t / rad, -0.995f, 0.995f);
                float slope = (grip_radius(&g, s + 0.5f) - grip_radius(&g, s - 0.5f));
                float ao = 1.f;
                if (s > g.knurl0 && s < g.knurl1) {
                    /* diamond knurl: two crossing helical grooves */
                    float arc = rad * asinf(nt);
                    float k = 6.2831853f / g.knurl_p;
                    float a1 = sinf(k * (s + arc)), a2 = sinf(k * (s - arc));
                    float fade = smooth(0.95f, 0.8f, fabsf(nt)); /* fades at grazing angles (aliasing) */
                    nt = clampf(nt + 0.22f * (a1 + a2) * fade * sqrtf(1.f - nt * nt), -0.995f, 0.995f);
                    slope += 0.30f * (a1 - a2) * fade;
                    ao = 1.f - 0.18f * fade * (1.f - a1 * a2) * 0.5f;
                }
                float nz = sqrtf(1.f - nt * nt);
                V3 n = norm3(v3(px * nt - c->hx * slope, py * nt - c->hy * slope, nz));
                /* soft occlusion towards the silhouette so the tube reads as round */
                ao *= 0.80f + 0.20f * nz;
                V3 m = chrome(n, ao);
                out_r = m.x * cov_h; out_g = m.y * cov_h; out_b = m.z * cov_h; out_a = cov_h;
            }

            /* rim */
            float cov_r = 0;
            if (r > rin - 1.f && r < ro + 1.f) {
                cov_r = sat(ro - r + 0.5f) * sat(r - rin + 0.5f);
                if (cov_r > 0.f) {
                    float u = sat((r - rin) / (ro - rin));
                    float nr = rim_normal_r(u);
                    float ux = r > 0 ? dx / r : 0, uy = r > 0 ? dy / r : 0;
                    V3 n = v3(ux * nr, uy * nr, sqrtf(1.f - nr * nr));
                    float ao = 1.f - 0.35f * (1.f - smooth(0.0f, 0.12f, u)) - 0.20f * smooth(0.92f, 1.0f, u);
                    V3 m = chrome(n, ao);
                    out_r = m.x * cov_r + out_r * (1.f - cov_r);
                    out_g = m.y * cov_r + out_g * (1.f - cov_r);
                    out_b = m.z * cov_r + out_b * (1.f - cov_r);
                    out_a = cov_r + out_a * (1.f - cov_r);
                }
            }

            col[i * 4 + 0] = out_r; col[i * 4 + 1] = out_g; col[i * 4 + 2] = out_b; col[i * 4 + 3] = out_a;
            float glass = sat(R - r + 0.5f);
            float m = fmaxf(out_a, glass * 0.28f);
            mask[i] = m;
        }
    }

    /* shadow: the silhouette shifted down-right and blurred */
    float *shadow = (float *)calloc((size_t)W * H, sizeof(float));
    if (!(c->flags & LENS_NO_SHADOW)) {
        int sx = (int)lroundf(0.045f * D), sy = (int)lroundf(0.075f * D);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                int xs = x - sx, ys = y - sy;
                if (xs >= 0 && ys >= 0 && xs < W && ys < H) shadow[(size_t)y * W + x] = mask[(size_t)ys * W + xs];
            }
        int br = (int)fmaxf(1.f, 0.022f * D);
        box_blur(shadow, tmp, W, H, br);
        box_blur(shadow, tmp, W, H, br);
        box_blur(shadow, tmp, W, H, br);
    }

    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            size_t i = (size_t)y * W + x;
            float dx = x + 0.5f - c->cx, dy = y + 0.5f - c->cy;
            /* no shadow under the glass itself: it is drawn over the screen contents */
            float sa = (dx * dx + dy * dy <= (c->R + 0.5f) * (c->R + 0.5f)) ? 0.f : shadow[i] * 0.42f;
            float a = col[i * 4 + 3];
            /* metal over shadow (shadow is black, so it only adds alpha) */
            float oa = a + sa * (1.f - a);
            c->stat[i] = pack(col[i * 4 + 0], col[i * 4 + 1], col[i * 4 + 2], oa);
        }

    free(mask);
    free(tmp);
    free(col);
    free(shadow);
}

/* Refraction (depends on the zoom): where each glass pixel looks on the screen. */
static void build_offsets(LensCtx *c) {
    const float R = c->R, m = c->zoom;
    const float k = 0.10f * (1.f - 1.f / m) + 0.02f; /* pincushion */
    float max_src = 0;
    for (int j = 0; j < c->gh; j++) {
        for (int i = 0; i < c->gw; i++) {
            GlassPx *p = &c->lut[(size_t)j * c->gw + i];
            if (!p->inside) continue;
            float dx = c->gx0 + i + 0.5f - c->cx, dy = c->gy0 + j + 0.5f - c->cy;
            float r = sqrtf(dx * dx + dy * dy);
            float q = fminf(r / R, 1.f);
            /* magnification, pincushion growing towards the rim, the steep ground edge */
            float src = r / m * (1.f - k * q * q);
            float edge = smooth(0.925f, 1.0f, q);
            src *= 1.f - 0.38f * edge * edge;
            float ca = 0.010f * q * q + 0.035f * edge * edge; /* lateral colour: blue bends more */
            float s_r = src * (1.f + ca), s_g = src, s_b = src * (1.f - ca);
            float ux = r > 0 ? dx / r : 0, uy = r > 0 ? dy / r : 0;
            p->rx = (int32_t)lroundf(ux * s_r * 256.f); p->ry = (int32_t)lroundf(uy * s_r * 256.f);
            p->gx = (int32_t)lroundf(ux * s_g * 256.f); p->gy = (int32_t)lroundf(uy * s_g * 256.f);
            p->bx = (int32_t)lroundf(ux * s_b * 256.f); p->by = (int32_t)lroundf(uy * s_b * 256.f);
            if (s_r > max_src) max_src = s_r;
        }
    }
    c->src_radius = (int)ceilf(max_src) + 2;
}

/* Reflections and transmission (independent of the zoom). */
static void build_optics(LensCtx *c) {
    const float R = c->R;
    const float rs = R / 0.55f; /* radius of the lens surface sphere */
    for (int j = 0; j < c->gh; j++) {
        for (int i = 0; i < c->gw; i++) {
            GlassPx *p = &c->lut[(size_t)j * c->gw + i];
            float dx = c->gx0 + i + 0.5f - c->cx, dy = c->gy0 + j + 0.5f - c->cy;
            float r = sqrtf(dx * dx + dy * dy);
            memset(p, 0, sizeof *p);
            if (r > R + 0.5f) continue;
            p->inside = 1;
            float q = fminf(r / R, 1.f);
            float ux = r > 0 ? dx / r : 0, uy = r > 0 ? dy / r : 0;

            /* surface normals of the convex front, and the mirrored back surface */
            float nx = dx / rs, ny = dy / rs;
            float nz = sqrtf(fmaxf(0.f, 1.f - nx * nx - ny * ny));
            V3 nf = v3(nx, ny, nz), nb = v3(-nx, -ny, nz);
            float F = 0.04f + 0.96f * powf(1.f - nz, 5.f);
            V3 rf = reflect_view(nf);
            V3 ef = env(rf, 1.3f), eb = env(reflect_view(nb), 1.f);
            float glint = powf(sat(dot3(rf, L_SUN)), 2500.f) * 2.5f;
            float fr = F * 1.25f, bk = F * 0.35f;
            float ar = ef.x * fr + eb.x * bk + glint, ag = ef.y * fr + eb.y * bk + glint, ab = ef.z * fr + eb.z * bk + glint;

            /* transmission: Fresnel loss, a touch of green, darker towards the edge */
            float T = (1.f - F) * (1.f - 0.10f * powf(q, 4.f));
            float tr = T * 0.985f, tg = T, tb = T * 0.99f;
            /* the ground edge of the glass: thick, greenish, dark, with a bright internal line */
            float band = smooth(0.955f, 0.99f, q);
            tr *= 1.f - 0.55f * band; tg *= 1.f - 0.42f * band; tb *= 1.f - 0.50f * band;
            float line = expf(-powf((q - 0.972f) / 0.009f, 2.f)) * 0.18f;
            /* brighter where the edge faces the key light, like a real bevel catching light */
            float facing = sat(-(ux * L_KEY.x + uy * L_KEY.y) * 1.2f);
            ar += line * (0.5f + facing); ag += line * (0.55f + facing); ab += line * (0.5f + facing);

            p->tr = (uint16_t)lroundf(sat(tr) * 256.f);
            p->tg = (uint16_t)lroundf(sat(tg) * 256.f);
            p->tb = (uint16_t)lroundf(sat(tb) * 256.f);
            p->ar = (uint8_t)lroundf(sat(ar) * 255.f);
            p->ag = (uint8_t)lroundf(sat(ag) * 255.f);
            p->ab = (uint8_t)lroundf(sat(ab) * 255.f);
        }
    }
}

LensCtx *lens_create(int diameter, float zoom, int flags) {
    env_init();
    if (diameter < 16) diameter = 16;
    if (diameter > 4096) diameter = 4096;
    LensCtx *c = (LensCtx *)calloc(1, sizeof(LensCtx));
    if (!c) return NULL;
    c->diameter = diameter;
    c->flags = flags;
    c->zoom = clampf(zoom, 1.f, 16.f);
    const float D = (float)diameter;
    c->R = D * 0.5f;
    c->rim_w = fmaxf(5.f, 0.075f * D);
    c->ro = c->R + c->rim_w;
    const float a = 0.70710678f;
    c->hx = (flags & LENS_HANDLE_LEFT) ? -a : a;
    c->hy = a;

    Grip g;
    grip_init(&g, D, c->R, c->ro, c->rim_w);
    float maxr = fmaxf(g.r_ferrule, fmaxf(g.r_col, g.r_grip * 1.2f));
    float ex = c->hx * g.s_cap, ey = c->hy * g.s_cap;
    float x0 = fminf(-c->ro, ex - maxr), x1 = fmaxf(c->ro, ex + maxr);
    float y0 = fminf(-c->ro, ey - maxr), y1 = fmaxf(c->ro, ey + maxr);
    if (!(flags & LENS_NO_SHADOW)) {
        float blur = 3.f * fmaxf(1.f, 0.022f * D) + 2.f;
        x0 = fminf(x0, x0 + 0.045f * D - blur); x1 = fmaxf(x1, x1 + 0.045f * D + blur);
        y0 = fminf(y0, y0 + 0.075f * D - blur); y1 = fmaxf(y1, y1 + 0.075f * D + blur);
    }
    x0 -= 2; y0 -= 2; x1 += 2; y1 += 2;
    c->cxi = (int)ceilf(-x0);
    c->cyi = (int)ceilf(-y0);
    c->W = c->cxi + (int)ceilf(x1) + 1;
    c->H = c->cyi + (int)ceilf(y1) + 1;
    c->cx = c->cxi + 0.5f;
    c->cy = c->cyi + 0.5f;

    int gr = (int)ceilf(c->R) + 2;
    c->gx0 = c->cxi - gr;
    c->gy0 = c->cyi - gr;
    c->gw = c->gh = 2 * gr + 1;

    c->stat = (uint32_t *)malloc((size_t)c->W * c->H * 4);
    c->lut = (GlassPx *)malloc((size_t)c->gw * c->gh * sizeof(GlassPx));
    if (!c->stat || !c->lut) {
        lens_destroy(c);
        return NULL;
    }
    build_static(c);
    build_optics(c);
    build_offsets(c);
    return c;
}

void lens_destroy(LensCtx *c) {
    if (!c) return;
    free(c->stat);
    free(c->lut);
    free(c);
}

void lens_set_zoom(LensCtx *c, float zoom) {
    zoom = clampf(zoom, 1.f, 16.f);
    if (fabsf(zoom - c->zoom) < 1e-4f) return;
    c->zoom = zoom;
    build_offsets(c);
}

int lens_width(const LensCtx *c) { return c->W; }
int lens_height(const LensCtx *c) { return c->H; }
int lens_center_x(const LensCtx *c) { return c->cxi; }
int lens_center_y(const LensCtx *c) { return c->cyi; }
int lens_source_radius(const LensCtx *c) { return c->src_radius; }
int lens_glass_top(const LensCtx *c) { return c->gy0; }
int lens_glass_bottom(const LensCtx *c) { return c->gy0 + c->gh; }

void lens_draw_static(const LensCtx *c, uint8_t *dst, int stride) {
    for (int y = 0; y < c->H; y++) memcpy(dst + (size_t)y * stride, c->stat + (size_t)y * c->W, (size_t)c->W * 4);
}

/* One channel, bilinear, clamped. f*: position in 1/256 px. */
static inline uint32_t sample(const uint8_t *src, int w, int h, int stride, int32_t fx, int32_t fy, int ch) {
    int32_t mx = (w - 1) << 8, my = (h - 1) << 8;
    if (fx < 0) fx = 0; else if (fx > mx) fx = mx;
    if (fy < 0) fy = 0; else if (fy > my) fy = my;
    int x0 = fx >> 8, y0 = fy >> 8;
    uint32_t ax = (uint32_t)(fx & 255), ay = (uint32_t)(fy & 255);
    int x1 = x0 + (x0 < w - 1), y1 = y0 + (y0 < h - 1);
    const uint8_t *r0 = src + (size_t)y0 * stride, *r1 = src + (size_t)y1 * stride;
    uint32_t a = r0[x0 * 4 + ch], b = r0[x1 * 4 + ch], cc = r1[x0 * 4 + ch], d = r1[x1 * 4 + ch];
    uint32_t top = a * (256 - ax) + b * ax, bot = cc * (256 - ax) + d * ax;
    return (top * (256 - ay) + bot * ay + 32768) >> 16;
}

void lens_draw_glass(const LensCtx *c, const uint8_t *src, int sw, int sh, int sstride, int scx, int scy,
                     uint8_t *dst, int stride, int y0, int y1) {
    if (y0 < c->gy0) y0 = c->gy0;
    if (y1 > c->gy0 + c->gh) y1 = c->gy0 + c->gh;
    if (sw <= 0 || sh <= 0) return;
    const int32_t ox = scx << 8, oy = scy << 8;
    for (int y = y0; y < y1; y++) {
        const GlassPx *lp = c->lut + (size_t)(y - c->gy0) * c->gw;
        const uint32_t *st = c->stat + (size_t)y * c->W + c->gx0;
        uint8_t *out = dst + (size_t)y * stride + (size_t)c->gx0 * 4;
        for (int i = 0; i < c->gw; i++, lp++, st++, out += 4) {
            if (!lp->inside) continue;
            uint32_t r = sample(src, sw, sh, sstride, ox + lp->rx, oy + lp->ry, 2);
            uint32_t g = sample(src, sw, sh, sstride, ox + lp->gx, oy + lp->gy, 1);
            uint32_t b = sample(src, sw, sh, sstride, ox + lp->bx, oy + lp->by, 0);
            r = (r * lp->tr) >> 8; g = (g * lp->tg) >> 8; b = (b * lp->tb) >> 8;
            /* screen blend of the reflections */
            r = r + lp->ar - (r * lp->ar + 127) / 255;
            g = g + lp->ag - (g * lp->ag + 127) / 255;
            b = b + lp->ab - (b * lp->ab + 127) / 255;
            /* static layer (rim edge) on top */
            uint32_t s = *st, sa = s >> 24, ia = 255 - sa;
            out[0] = (uint8_t)((s & 255) + (b * ia + 127) / 255);
            out[1] = (uint8_t)(((s >> 8) & 255) + (g * ia + 127) / 255);
            out[2] = (uint8_t)(((s >> 16) & 255) + (r * ia + 127) / 255);
            out[3] = 255;
        }
    }
}
