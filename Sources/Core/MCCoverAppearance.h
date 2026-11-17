#ifndef MCCoverAppearance_h
#define MCCoverAppearance_h
#include "MCColor.h"
#include "MCNowPlayingLayout.h"

#define MCCoverGradientStops 13
#define MCCoverColorColumns 7
#define MCCoverColorRows 3
typedef struct {
    MCColor color;
    double lightness, chromaA, chromaB;
    double brightness, saturation, variation, confidence, strength;
} MCCoverColorNode;
typedef struct {
    MCColor tint, foreground;
    double opacity[MCCoverGradientStops];
    double fadeEnd;
    double minimumContrast, readableFraction;
    bool needsTextOutline;
    unsigned columns, rows;
    MCCoverColorNode nodes[MCCoverColorColumns * MCCoverColorRows];
} MCCoverAppearance;

/* RGBA is premultiplied, in display orientation after Aspect Fill cropping.
   Theme colors are only a fallback for transparent or missing artwork. */
bool MCCoverAppearanceMake(const uint8_t *rgba, unsigned width, unsigned height,
                          size_t stride, double cardWidth, double cardHeight,
                          MCPlayerCoverLayout layout, MCColor fallback,
                          MCCoverAppearance *out);
/* Coordinates are normalized within the information overlay. Color and opacity
   are independent, continuously interpolated two-dimensional fields. */
MCColor MCCoverGradientColor(MCCoverAppearance appearance, double x, double y);
double MCCoverGradientAlpha(MCCoverAppearance appearance, double x, double y);
bool MCCoverGradientRenderRGBA(MCCoverAppearance appearance, uint8_t *rgba,
                              unsigned width, unsigned height, size_t stride);
/* Compatibility accessors for the center-line vertical curve. */
double MCCoverGradientOpacity(MCCoverAppearance appearance, double position);
double MCCoverGradientPosition(MCCoverAppearance appearance, unsigned index);
MCCoverAppearance MCCoverAppearanceFallback(MCColor background);
#endif
