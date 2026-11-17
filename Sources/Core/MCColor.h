#ifndef MCColor_h
#define MCColor_h
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct {
    double r, g, b;
} MCColor;
bool MCColorParse(const char *hex, MCColor *out);
double MCColorContrast(MCColor a, MCColor b);
MCColor MCColorForeground(MCColor background);
MCColor MCColorAccent(MCColor color, bool dark);
MCColor MCColorReadableAccent(MCColor color, bool dark, MCColor background);
MCColor MCColorBlend(MCColor base, MCColor tint, double amount);
typedef struct {
    MCColor background, surface, container, containerHigh, primaryContainer, onContainer;
    MCColor primary, onPrimary, text, muted, outline, accent;
} MCMaterialPalette;
MCMaterialPalette MCColorMaterialPalette(MCColor seed, bool dark);
bool MCColorArtwork(const uint8_t *rgba, unsigned width, unsigned height, size_t stride, MCColor *out);
#endif
