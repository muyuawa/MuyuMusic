#ifndef MCCoverAppearance_h
#define MCCoverAppearance_h
#include "MCColor.h"
#include "MCNowPlayingLayout.h"

#define MCCoverGradientStops 13
typedef struct {
    MCColor tint, foreground;
    double opacity[MCCoverGradientStops];
    double fadeEnd;
    double minimumContrast, readableFraction;
    bool needsTextOutline;
} MCCoverAppearance;

/* RGBA is premultiplied, in display orientation after Aspect Fill cropping.
   Theme colors are only a fallback for transparent or missing artwork. */
bool MCCoverAppearanceMake(const uint8_t *rgba, unsigned width, unsigned height,
                          size_t stride, double cardWidth, double cardHeight,
                          MCPlayerCoverLayout layout, MCColor fallback,
                          MCCoverAppearance *out);
/* Matches the piecewise interpolation of the persistent CAGradientLayer. */
double MCCoverGradientOpacity(MCCoverAppearance appearance, double position);
double MCCoverGradientPosition(MCCoverAppearance appearance, unsigned index);
MCCoverAppearance MCCoverAppearanceFallback(MCColor background);
#endif
