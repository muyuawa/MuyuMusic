#ifndef MCNowPlayingLayout_h
#define MCNowPlayingLayout_h
#include <stdbool.h>

typedef struct { double x, y, width, height; } MCPlayerRect;
typedef struct {
    MCPlayerRect mode, body, cover, title, artist, quality;
    MCPlayerRect slider, elapsed, total, status;
    MCPlayerRect previous, play, next, repeat, shuffle, favorite;
} MCNowPlayingLayout;

/* Coordinates are relative to the visible area below the navigation bar. */
MCNowPlayingLayout MCNowPlayingMakeLayout(double width, double height);
double MCLyricCenterInset(double height, double rowHeight);
double MCLyricCenterOffset(unsigned row, double height, double rowHeight);
bool MCLyricCanFollow(double now, double resumeAfter, bool dragging, bool decelerating);
#endif
