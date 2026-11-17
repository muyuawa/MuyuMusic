#ifndef MCDiscoverLayout_h
#define MCDiscoverLayout_h
#include "MCNowPlayingLayout.h"
typedef struct {
    MCPlayerRect hero, shortcuts[4], shelfMode, shelfMore, shelf, heading;
    double height, tileWidth;
} MCDiscoverLayout;
MCDiscoverLayout MCDiscoverMakeLayout(double width);
#endif
