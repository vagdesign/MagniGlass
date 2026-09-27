/* Renders the glass over a picture: preview in.ppm out.ppm diameter zoom x y [flags]
   (the picture stands in for the screen; x y is the pointer). Used to check the look
   without a Windows or Mac machine. */
#include "../core/lenscore.h"
#include <stdio.h>
#include <stdlib.h>

static unsigned char *read_ppm(const char *path, int *w, int *h) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    int maxv;
    if (fscanf(f, "P6 %d %d %d", w, h, &maxv) != 3) { fclose(f); return NULL; }
    fgetc(f);
    size_t n = (size_t)*w * *h * 3;
    unsigned char *rgb = malloc(n);
    size_t got = fread(rgb, 1, n, f);
    fclose(f);
    if (got != n) { free(rgb); return NULL; }
    unsigned char *bgra = malloc((size_t)*w * *h * 4);
    for (int i = 0; i < *w * *h; i++) {
        bgra[i * 4] = rgb[i * 3 + 2]; bgra[i * 4 + 1] = rgb[i * 3 + 1]; bgra[i * 4 + 2] = rgb[i * 3]; bgra[i * 4 + 3] = 255;
    }
    free(rgb);
    return bgra;
}

int main(int argc, char **argv) {
    if (argc < 7) { fprintf(stderr, "usage: preview in.ppm out.ppm diameter zoom x y [flags]\n"); return 1; }
    int w, h;
    unsigned char *scr = read_ppm(argv[1], &w, &h);
    if (!scr) { fprintf(stderr, "cannot read %s\n", argv[1]); return 1; }
    int d = atoi(argv[3]), px = atoi(argv[5]), py = atoi(argv[6]);
    float zoom = (float)atof(argv[4]);
    int flags = argc > 7 ? atoi(argv[7]) : 0;
    LensCtx *c = lens_create(d, zoom, flags);
    int W = lens_width(c), H = lens_height(c);
    unsigned char *img = calloc((size_t)W * H, 4);
    lens_draw_static(c, img, W * 4);
    lens_draw_glass(c, scr, w, h, w * 4, px, py, img, W * 4, 0, H);
    fprintf(stderr, "image %dx%d centre %d,%d source radius %d\n", W, H, lens_center_x(c), lens_center_y(c), lens_source_radius(c));
    int ox = px - lens_center_x(c), oy = py - lens_center_y(c);
    FILE *f = fopen(argv[2], "wb");
    fprintf(f, "P6 %d %d 255\n", w, h);
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            unsigned char *s = scr + ((size_t)y * w + x) * 4;
            int r = s[2], g = s[1], b = s[0];
            int lx = x - ox, ly = y - oy;
            if (lx >= 0 && ly >= 0 && lx < W && ly < H) {
                unsigned char *l = img + ((size_t)ly * W + lx) * 4;
                int ia = 255 - l[3];
                r = l[2] + r * ia / 255; g = l[1] + g * ia / 255; b = l[0] + b * ia / 255;
            }
            fputc(r, f); fputc(g, f); fputc(b, f);
        }
    fclose(f);
    lens_destroy(c);
    return 0;
}
