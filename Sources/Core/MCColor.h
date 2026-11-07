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
bool MCColorArtwork(const uint8_t *rgba, unsigned width, unsigned height, size_t stride, MCColor *out);
#endif
