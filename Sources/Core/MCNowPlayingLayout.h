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
/* Root-view coordinates; a hidden tab bar may still have its visible frame. */
MCPlayerRect MCMiniPlayerMakeFrame(double width, double height, double tabBarTop, bool tabBarHidden);
double MCLyricCenterInset(double height, double rowHeight);
double MCLyricCenterOffset(unsigned row, double height, double rowHeight);
bool MCLyricCanFollow(double now, double resumeAfter, bool dragging, bool decelerating);
double MCMiniDragOffset(double translation, double width, bool available);
/* -1 next, +1 previous, 0 return to current. */
int MCMiniDragDestination(double translation, double velocity, double width, bool previous, bool next);
#endif
