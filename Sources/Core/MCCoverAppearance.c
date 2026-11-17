#include "MCCoverAppearance.h"
#include <math.h>
#include <string.h>

static double clamp(double value, double low, double high) {
    return fmax(low, fmin(high, value));
}
static double brightness(MCColor color) {
    return .2126 * color.r + .7152 * color.g + .0722 * color.b;
}
static MCColor pixel(const uint8_t *rgba, MCColor fallback) {
    double alpha = rgba[3] / 255.;
    return (MCColor){rgba[0] / 255. + fallback.r * (1 - alpha),
                     rgba[1] / 255. + fallback.g * (1 - alpha),
                     rgba[2] / 255. + fallback.b * (1 - alpha)};
}
static double percentile(const unsigned histogram[256], unsigned count, double fraction) {
    unsigned accumulated = 0;
    for (unsigned i = 0; i < 256; i++) {
        accumulated += histogram[i];
        if (accumulated > count * fraction) return i / 255.;
    }
    return 0;
}
static void curve(MCCoverAppearance *appearance, double strength) {
    for (unsigned i = 0; i < MCCoverGradientStops; i++) {
        double t = i <= 6 ? i / 6. : (i - 6) / 6.;
        double eased = t * t * (3 - 2 * t);
        appearance->opacity[i] = i <= 6 ? strength * eased : strength + fmin(.02, 1 - strength) * eased;
    }
}
double MCCoverGradientPosition(MCCoverAppearance appearance, unsigned index) {
    if (index >= MCCoverGradientStops - 1) return 1;
    double end = clamp(appearance.fadeEnd, .05, .65);
    return index <= 6 ? end * index / 6. : end + (1 - end) * (index - 6) / 6.;
}
double MCCoverGradientOpacity(MCCoverAppearance appearance, double position) {
    double t = clamp(position, 0, 1);
    for (unsigned i = 0; i < MCCoverGradientStops - 1; i++) {
        double left = MCCoverGradientPosition(appearance, i), right = MCCoverGradientPosition(appearance, i + 1);
        if (t <= right)
            return appearance.opacity[i] + (appearance.opacity[i + 1] - appearance.opacity[i]) * (t - left) / (right - left);
    }
    return appearance.opacity[MCCoverGradientStops - 1];
}
MCCoverAppearance MCCoverAppearanceFallback(MCColor background) {
    MCCoverAppearance appearance = {0};
    appearance.tint = background;
    appearance.fadeEnd = .25;
    appearance.foreground = MCColorForeground(background);
    appearance.minimumContrast = MCColorContrast(background, appearance.foreground);
    appearance.readableFraction = 1;
    curve(&appearance, .06);
    return appearance;
}
static bool contains(MCPlayerRect rect, double x, double y) {
    return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
}
static void contrast(const uint8_t *rgba, unsigned width, unsigned height, size_t stride,
                     double cardWidth, double cardHeight, MCPlayerCoverLayout layout,
                     MCColor fallback, MCCoverAppearance *appearance) {
    double total = 0, readable = 0, minimum = 21;
    MCPlayerRect favorite = layout.favorite;
    favorite.x += 10; favorite.y += 10; favorite.width -= 20; favorite.height -= 20;
    for (unsigned y = 0; y < height; y++) {
        double py = (y + .5) * cardHeight / height;
        double opacity = MCCoverGradientOpacity(*appearance, (py - layout.panel.y) / layout.panel.height);
        for (unsigned x = 0; x < width; x++) {
            double px = (x + .5) * cardWidth / width;
            double weight = contains(layout.title, px, py) ? 3 : contains(layout.artist, px, py) ? 2 :
                contains(favorite, px, py) ? 1 : 0;
            if (!weight) continue;
            MCColor background = MCColorBlend(pixel(rgba + y * stride + x * 4, fallback), appearance->tint, opacity);
            double ratio = MCColorContrast(background, appearance->foreground);
            minimum = fmin(minimum, ratio);
            total += weight;
            if (ratio >= 4.5) readable += weight;
        }
    }
    appearance->minimumContrast = minimum;
    appearance->readableFraction = total ? readable / total : 1;
    appearance->needsTextOutline = minimum < 4.5;
}
bool MCCoverAppearanceMake(const uint8_t *rgba, unsigned width, unsigned height,
                          size_t stride, double cardWidth, double cardHeight,
                          MCPlayerCoverLayout layout, MCColor fallback, MCCoverAppearance *out) {
    if (!rgba || !out || !width || !height || width > 64 || height > 64 || stride < width * 4 ||
        !isfinite(cardWidth) || !isfinite(cardHeight) || cardWidth <= 0 || cardHeight <= 0 ||
        !isfinite(layout.panel.y) || !isfinite(layout.panel.height) || layout.panel.height <= 0) return false;
    unsigned histogram[4][256] = {{0}}, count = 0, edges = 0;
    MCColor sum = {0};
    double light = 0, squared = 0;
    /* A median-weighted local color retains a white background even when a
       dark logo dominates the full-cover theme extraction. Include neutral
       pixels instead of discarding them as the theme hue extractor does. */
    for (unsigned y = 0; y < height; y++) {
        if ((y + .5) * cardHeight / height < layout.title.y - 2) continue;
        for (unsigned x = 0; x < width; x++) {
            MCColor color = pixel(rgba + y * stride + x * 4, fallback);
            histogram[0][(unsigned)round(clamp(color.r, 0, 1) * 255)]++;
            histogram[1][(unsigned)round(clamp(color.g, 0, 1) * 255)]++;
            histogram[2][(unsigned)round(clamp(color.b, 0, 1) * 255)]++;
            sum.r += color.r; sum.g += color.g; sum.b += color.b;
            double b = brightness(color);
            histogram[3][(unsigned)round(clamp(b, 0, 1) * 255)]++;
            bool edge = x && fabs(b - brightness(pixel(rgba + y * stride + (x - 1) * 4, fallback))) > .16;
            if (y && fabs(b - brightness(pixel(rgba + (y - 1) * stride + x * 4, fallback))) > .16) edge = true;
            if (edge) edges++;
            light += b; squared += b * b; count++;
        }
    }
    if (!count) return false;
    MCColor average = {sum.r / count, sum.g / count, sum.b / count};
    MCColor middle = {percentile(histogram[0], count, .5), percentile(histogram[1], count, .5), percentile(histogram[2], count, .5)};
    bool paper = brightness(middle) > .75 && fmax(middle.r, fmax(middle.g, middle.b)) - fmin(middle.r, fmin(middle.g, middle.b)) < .12;
    if (paper) average = MCColorBlend(middle, average, .5);
    MCColor local = MCColorBlend(middle, average, .3);
    double variance = fmax(0, squared / count - (light / count) * (light / count));
    MCCoverAppearance appearance = {0};
    appearance.fadeEnd = clamp((layout.title.y - layout.panel.y) / layout.panel.height, .05, .65);
    appearance.foreground = MCColorForeground(local);
    MCColor end = appearance.foreground.r == 0 ? (MCColor){1,1,1} : (MCColor){0,0,0};
    appearance.tint = local;
    /* Correct brightness toward the local light/dark direction; retain the
       original hue and never replace a blue cover with a black theme tint. */
    for (unsigned i = 0; i < 20 && MCColorContrast(appearance.tint, appearance.foreground) < 7; i++)
        appearance.tint = MCColorBlend(appearance.tint, end, .025);
    double baseline = clamp((appearance.foreground.r == 0 ? .035 : .10) + variance * .3, .035, .18);
    double spread = percentile(histogram[3], count, .95) - percentile(histogram[3], count, .05);
    /* Foreground contrast alone does not distinguish the song text from
       letters already printed on the artwork. Suppress strong local texture
       before the first title row, especially dark logos on light paper. */
    if (spread > .18 && (edges / (double)count > .015 || variance > .05)) {
        double protection = paper ? .86 : .50 + .32 * clamp((spread - .18) / .52, 0, 1);
        baseline = fmax(baseline, protection);
    }
    double maximum = .96;
    MCCoverAppearance best = appearance;
    curve(&best, baseline);
    contrast(rgba, width, height, stride, cardWidth, cardHeight, layout, fallback, &best);
    /* Reach the actual per-region contrast target. The short fade above
       the information can stay transparent while the first glyphs already
       receive the necessary protection. */
    MCCoverAppearance strongest = appearance;
    curve(&strongest, maximum);
    contrast(rgba, width, height, stride, cardWidth, cardHeight, layout, fallback, &strongest);
    double lower = baseline, upper = maximum;
    bool search = best.minimumContrast < 4.5;
    for (unsigned step = 0; search && step < 8; step++) {
        MCCoverAppearance candidate = appearance;
        double strength = (lower + upper) / 2;
        curve(&candidate, strength);
        contrast(rgba, width, height, stride, cardWidth, cardHeight, layout, fallback, &candidate);
        if (candidate.minimumContrast >= 4.5) { best = candidate; upper = strength; }
        else lower = strength;
    }
    if (best.minimumContrast < 4.5) best = strongest;
    *out = best;
    return true;
}
