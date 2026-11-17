#include "MCCoverAppearance.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static uint8_t pixels[48 * 48 * 4];
static MCColor fallback = {.15,.13,.18};
static void fill(unsigned r, unsigned g, unsigned b) {
    for (unsigned i = 0; i < 48 * 48; i++) {
        pixels[i * 4] = r; pixels[i * 4 + 1] = g;
        pixels[i * 4 + 2] = b; pixels[i * 4 + 3] = 255;
    }
}
static MCCoverAppearance analyze(double side, unsigned lines) {
    MCCoverAppearance appearance;
    MCPlayerCoverLayout layout = MCPlayerCoverMakeLayout(side, side, lines);
    assert(MCCoverAppearanceMake(pixels, 48, 48, 48 * 4, side, side, layout, fallback, &appearance));
    assert(appearance.opacity[0] == 0);
    assert(appearance.opacity[MCCoverGradientStops - 1] <= .98);
    assert(appearance.foreground.r == 0 || appearance.foreground.r == 1);
    for (unsigned i = 1; i < MCCoverGradientStops; i++)
        assert(appearance.opacity[i] >= 0 && appearance.opacity[i] <= .98);
    assert(MCCoverGradientOpacity(appearance, -.1) == 0);
    assert(MCCoverGradientOpacity(appearance, 1.1) == appearance.opacity[MCCoverGradientStops - 1]);
    assert(MCCoverGradientOpacity(appearance, .001) < .01);
    assert(MCCoverGradientPosition(appearance, 0) == 0 && MCCoverGradientPosition(appearance, 12) == 1);
    assert(MCCoverGradientOpacity(appearance, appearance.fadeEnd) >= appearance.opacity[6] - .00001);
    assert(appearance.needsTextOutline == (appearance.minimumContrast < 4.5));
    return appearance;
}
int main(void) {
    /* White paper with a black logo in the upper two thirds must not be
       converted into a dark panel by the global theme's representative hue. */
    fill(249, 249, 247);
    MCCoverAppearance plain = analyze(220, 1);
    for (unsigned y = 8; y < 28; y++) for (unsigned x = 6; x < 42; x++) {
        uint8_t *p = pixels + (y * 48 + x) * 4;
        p[0] = p[1] = p[2] = 12;
    }
    MCCoverAppearance logo = analyze(220, 1);
    assert(logo.tint.r > .95 && logo.tint.g > .95 && logo.tint.b > .94);
    assert(logo.foreground.r == 0 && logo.minimumContrast >= 4.5 && !logo.needsTextOutline);
    assert(logo.opacity[MCCoverGradientStops - 1] < .08);
    assert(fabs(logo.tint.r - plain.tint.r) < .0001);
    puts("white logo: original brightness, dark readable text, minimal local tint");

    /* The reported logo occupies the information itself, unlike the old
       fixture. Readable foreground color alone must not count as a pass:
       the underlying letters also need to fade out. */
    fill(249, 249, 247);
    for (unsigned y = 34; y < 44; y++) for (unsigned x = 6; x < 42; x++) {
        if (x % 5 >= 2 && y % 8 >= 2) continue;
        uint8_t *p = pixels + (y * 48 + x) * 4;
        p[0] = p[1] = p[2] = 40;
    }
    MCCoverAppearance bottomLogo = analyze(220, 1);
    assert(bottomLogo.tint.r > .9 && bottomLogo.foreground.r == 0);
    assert(bottomLogo.opacity[6] >= .8 && bottomLogo.minimumContrast >= 4.5);
    MCColor fadedInk = MCColorBlend((MCColor){40/255.,40/255.,40/255.},bottomLogo.tint,bottomLogo.opacity[6]);
    MCColor fadedPaper = MCColorBlend((MCColor){249/255.,249/255.,247/255.},bottomLogo.tint,bottomLogo.opacity[6]);
    assert(MCColorContrast(fadedInk,fadedPaper) < 1.6);
    assert(!bottomLogo.needsTextOutline);
    puts("bottom logo regression: strong light protection at the first title row, original lettering fades");

    /* A darker upper half and a light lower half must still select dark
       cover text, independent of the app's dark theme. */
    for (unsigned y = 0; y < 30; y++) for (unsigned x = 0; x < 48; x++) {
        uint8_t *p = pixels + (y * 48 + x) * 4;
        p[0] = 10; p[1] = 25; p[2] = 80;
    }
    assert(analyze(288, 2).foreground.r == 0);

    fill(18, 40, 76);
    MCCoverAppearance blue = analyze(220, 1);
    assert(blue.tint.b > blue.tint.r * 2 && blue.tint.b > .2);
    assert(blue.foreground.r == 1 && blue.minimumContrast >= 4.5 && !blue.needsTextOutline);
    assert(blue.opacity[MCCoverGradientStops - 1] <= .15);
    puts("dark blue: preserved hue, light readable text, moderate gradient");

    /* A narrow midtone strip under the artist/favorite can be repaired by
       a small adaptive increase without changing a bright cover's palette. */
    fill(230, 230, 230);
    for (unsigned y = 38; y < 42; y++) for (unsigned x = 0; x < 48; x++) {
        uint8_t *p = pixels + (y * 48 + x) * 4;
        p[0] = p[1] = p[2] = 109;
    }
    MCCoverAppearance stripe = analyze(220, 1);
    assert(stripe.foreground.r == 0);
    assert(stripe.opacity[MCCoverGradientStops - 1] > .07 && stripe.opacity[MCCoverGradientStops - 1] <= .98);
    assert(stripe.minimumContrast >= 4.5 && stripe.readableFraction == 1);
    puts("local contrast strip: adaptive strength repairs readable coverage without an opaque slab");

    /* Bright/dark artwork directly beneath the glyphs needs a light edge
       instead of an opaque bottom block. The edge contrasts with either
       foreground at 21:1; the background-only result is reported honestly. */
    for (unsigned y = 0; y < 48; y++) for (unsigned x = 0; x < 48; x++) {
        uint8_t *p = pixels + (y * 48 + x) * 4;
        bool light = ((x / 3 + y / 3) % 2) == 0;
        p[0] = light ? 250 : 10; p[1] = light ? 180 : 30; p[2] = light ? 230 : 100; p[3] = 255;
    }
    const double sizes[] = {200, 216, 220, 288, 343, 382, 480};
    for (unsigned i = 0; i < sizeof sizes / sizeof *sizes; i++) {
        MCCoverAppearance appearance = analyze(sizes[i], 2);
        assert(!appearance.needsTextOutline);
        assert(appearance.minimumContrast >= 4.5 && appearance.readableFraction == 1);
        assert(appearance.opacity[MCCoverGradientStops - 1] <= .98);
        MCColor edge = appearance.foreground.r == 0 ? (MCColor){1,1,1} : (MCColor){0,0,0};
        assert(MCColorContrast(edge, appearance.foreground) == 21);
        for (unsigned background = 0; background < 2; background++) {
            MCColor behind = {background,background,background};
            assert(MCColorContrast(MCColorBlend(behind, edge, .78), appearance.foreground) >= 4.5);
        }
    }
    puts("complex color: protected background reaches 4.5:1 before relying on outlines, all card sizes");

    /* A genuine color field keeps both horizontal and vertical artwork
       differences after coordinating lightness for a single text color. */
    for (unsigned y = 0; y < 48; y++) for (unsigned x = 0; x < 48; x++) {
        uint8_t *p = pixels + (y * 48 + x) * 4;
        double t = x / 47., v = y / 47.;
        p[0] = (uint8_t)(70 + 120*t + 20*v);
        p[1] = (uint8_t)(45 + 40*t + 30*v);
        p[2] = (uint8_t)(155 - 30*t + 20*v); p[3] = 255;
    }
    MCCoverAppearance field = analyze(220, 1);
    assert(field.columns == 5 && field.rows == 3);
    MCColor left = MCCoverGradientColor(field,.05,.7), right = MCCoverGradientColor(field,.95,.7);
    assert(fabs(left.r-right.r) + fabs(left.b-right.b) > .05);
    MCColor above = MCCoverGradientColor(field,.5,.1), below = MCCoverGradientColor(field,.5,.9);
    assert(fabs(above.r-below.r) + fabs(above.b-below.b) > .01);
    assert(analyze(480, 1).columns == 7);
    for (unsigned i = 0; i < field.columns*field.rows; i++) {
        assert(field.nodes[i].confidence >= 0 && field.nodes[i].confidence <= 1);
        assert(field.nodes[i].variation >= 0 && field.nodes[i].strength <= .96);
    }
    for (unsigned x = 1; x < 1000; x++) {
        MCColor a = MCCoverGradientColor(field,(x-1)/1000.,.7), b = MCCoverGradientColor(field,x/1000.,.7);
        assert(fabs(a.r-b.r) + fabs(a.g-b.g) + fabs(a.b-b.b) < .02);
    }
    uint8_t overlay[64*48*4];
    assert(MCCoverGradientRenderRGBA(field,overlay,64,48,64*4));
    for (unsigned x = 0; x < 64*4; x++) assert(overlay[x] == 0);
    for (unsigned i = 0; i < 64*48; i++) {
        assert(overlay[i*4] <= overlay[i*4+3] && overlay[i*4+1] <= overlay[i*4+3] && overlay[i*4+2] <= overlay[i*4+3]);
    }
    puts("two-dimensional field: horizontal/vertical color differences, continuous interpolation and transparent edge");

    memset(pixels, 0, sizeof pixels);
    MCCoverAppearance transparent = analyze(220, 1);
    assert(transparent.foreground.r == MCColorForeground(fallback).r);
    assert(transparent.minimumContrast >= 4.5);
    MCCoverAppearance missing = MCCoverAppearanceFallback((MCColor){.96,.94,.98});
    assert(missing.foreground.r == 0 && missing.minimumContrast >= 4.5);
    MCPlayerCoverLayout layout = MCPlayerCoverMakeLayout(220, 220, 1);
    assert(!MCCoverAppearanceMake(NULL, 48, 48, 192, 220, 220, layout, fallback, &missing));
    assert(!MCCoverAppearanceMake(pixels, 0, 48, 192, 220, 220, layout, fallback, &missing));
    assert(!MCCoverAppearanceMake(pixels, 48, 48, 8, 220, 220, layout, fallback, &missing));
    assert(!MCCoverAppearanceMake(pixels, 48, 48, 192, NAN, 220, layout, fallback, &missing));
    puts("missing/transparent artwork and invalid inputs: stable fallback");

    clock_t start = clock();
    for (unsigned i = 0; i < 100; i++) {
        fill((i * 71) % 256, (i * 31) % 256, (i * 17) % 256);
        analyze(220, 1);
    }
    printf("100 bounded 48x48 analyses: %.1f ms on this host (not device timing)\n",
           1000. * (clock() - start) / CLOCKS_PER_SEC);
    return 0;
}
