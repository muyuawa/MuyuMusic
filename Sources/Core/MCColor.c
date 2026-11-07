#include "MCColor.h"
#include <math.h>
#include <string.h>
static int digit(char x) {
    if (x >= '0' && x <= '9')
        return x - '0';
    if (x >= 'a' && x <= 'f')
        return x - 'a' + 10;
    if (x >= 'A' && x <= 'F')
        return x - 'A' + 10;
    return -1;
}
bool MCColorParse(const char *hex, MCColor *out) {
    if (!hex || !out)
        return false;
    if (*hex == '#')
        ++hex;
    if (strlen(hex) != 6)
        return false;
    unsigned value = 0;
    for (unsigned i = 0; i < 6; i++) {
        int d = digit(hex[i]);
        if (d < 0)
            return false;
        value = value * 16 + (unsigned)d;
    }
    *out = (MCColor){(value >> 16) / 255.0, ((value >> 8) & 255) / 255.0, (value & 255) / 255.0};
    return true;
}
static double linear(double x) {
    return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4);
}
static double luma(MCColor c) {
    return .2126 * linear(c.r) + .7152 * linear(c.g) + .0722 * linear(c.b);
}
double MCColorContrast(MCColor a, MCColor b) {
    double x = luma(a), y = luma(b);
    return (fmax(x, y) + .05) / (fmin(x, y) + .05);
}
MCColor MCColorForeground(MCColor bg) {
    MCColor black = {0, 0, 0}, white = {1, 1, 1};
    return MCColorContrast(bg, black) >= MCColorContrast(bg, white) ? black : white;
}
MCColor MCColorAccent(MCColor c, bool dark) {
    MCColor background = dark ? (MCColor){36.0 / 255, 44.0 / 255, 60.0 / 255} : (MCColor){1, 1, 1};
    return MCColorReadableAccent(c, dark, background);
}
MCColor MCColorReadableAccent(MCColor c, bool dark, MCColor background) {
    for (unsigned i = 0; i < 100 && MCColorContrast(c, background) < 4.5; i++) {
        double end = dark ? 1 : 0;
        c.r = c.r * .94 + end * .06;
        c.g = c.g * .94 + end * .06;
        c.b = c.b * .94 + end * .06;
    }
    return c;
}
MCColor MCColorBlend(MCColor base, MCColor tint, double amount) {
    return (MCColor){base.r*(1-amount)+tint.r*amount, base.g*(1-amount)+tint.g*amount,
                     base.b*(1-amount)+tint.b*amount};
}
bool MCColorArtwork(const uint8_t *rgba, unsigned width, unsigned height, size_t stride, MCColor *out) {
    if (!rgba || !out || !width || !height || width > 64 || height > 64 || stride < width*4)
        return false;
    double scores[512] = {0}, red[512] = {0}, green[512] = {0}, blue[512] = {0};
    MCColor neutral = {0};
    unsigned usable = 0, best = 0;
    for (unsigned y = 0; y < height; y++) for (unsigned x = 0; x < width; x++) {
        const uint8_t *p = rgba + y*stride + x*4;
        if (p[3] < 224) continue;
        double r=p[0]/255.0, g=p[1]/255.0, b=p[2]/255.0;
        double high=fmax(r,fmax(g,b)), low=fmin(r,fmin(g,b));
        if (high < .12 || low > .93) continue;
        neutral.r += r; neutral.g += g; neutral.b += b; usable++;
        double saturation = (high-low)/fmax(.001,high);
        if (saturation < .1) continue;
        unsigned bin=((unsigned)p[0]>>5)*64+((unsigned)p[1]>>5)*8+((unsigned)p[2]>>5);
        double weight=saturation*saturation;
        scores[bin]+=weight; red[bin]+=r*weight; green[bin]+=g*weight; blue[bin]+=b*weight;
        if (scores[bin] > scores[best]) best=bin;
    }
    if (scores[best] > 0) {
        *out=(MCColor){red[best]/scores[best],green[best]/scores[best],blue[best]/scores[best]};
        return true;
    }
    if (!usable) return false;
    *out=(MCColor){neutral.r/usable,neutral.g/usable,neutral.b/usable};
    return true;
}
