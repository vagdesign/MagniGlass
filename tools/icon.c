/* Renders the app icon with the lens renderer itself: icon out.rgba diameter
   (glass over a soft blue page with a few lines of "text"; transparent elsewhere). */
#include "../core/lenscore.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 3) return 1;
    int d = atoi(argv[2]);
    LensCtx *c = lens_create(d, 2.2f, LENS_NO_SHADOW);
    int W = lens_width(c), H = lens_height(c);
    /* source "page": light gradient with text-like bars */
    int sw = d, sh = d;
    unsigned char *src = malloc((size_t)sw * sh * 4);
    for (int y = 0; y < sh; y++)
        for (int x = 0; x < sw; x++) {
            float t = (float)y / sh;
            int r = (int)(222 - 40 * t), g = (int)(238 - 28 * t), b = 252;
            int line = (y / (sh / 14)) % 2 == 1 && x > sw * 0.18 && x < sw * (0.82 - 0.2 * ((y / (sh / 14)) % 3 == 0));
            if (line && (y % (sh / 14)) > sh / 70) { r = 44; g = 62; b = 96; }
            unsigned char *p = src + ((size_t)y * sw + x) * 4;
            p[0] = (unsigned char)b; p[1] = (unsigned char)g; p[2] = (unsigned char)r; p[3] = 255;
        }
    unsigned char *img = calloc((size_t)W * H, 4);
    lens_draw_static(c, img, W * 4);
    lens_draw_glass(c, src, sw, sh, sw * 4, sw / 2, sh / 2, img, W * 4, 0, H);
    /* centre the whole magnifier (lens + grip) in a square canvas */
    int size = W > H ? W : H;
    int ox = (size - W) / 2, oy = (size - H) / 2;
    FILE *f = fopen(argv[1], "wb");
    fprintf(f, "%d\n", size); /* then size*size straight RGBA pixels */
    for (int y = 0; y < size; y++)
        for (int x = 0; x < size; x++) {
            int lx = x - ox, ly = y - oy;
            unsigned char px[4] = {0, 0, 0, 0};
            if (lx >= 0 && ly >= 0 && lx < W && ly < H) {
                unsigned char *s = img + ((size_t)ly * W + lx) * 4;
                int a = s[3];
                if (a) { px[0] = (unsigned char)(s[2] * 255 / a); px[1] = (unsigned char)(s[1] * 255 / a); px[2] = (unsigned char)(s[0] * 255 / a); px[3] = (unsigned char)a; }
            }
            fwrite(px, 1, 4, f);
        }
    fclose(f);
    fprintf(stderr, "icon source %dx%d\n", W, H);
    return 0;
}
