#include "MCNowPlayingLayout.h"
#include <math.h>

static MCPlayerRect rect(double x, double y, double w, double h) {
    return (MCPlayerRect){x, y, w, h};
}
MCNowPlayingLayout MCNowPlayingMakeLayout(double width, double height) {
    MCNowPlayingLayout l = {0};
    double footer = height - 134;
    double bodyHeight = fmax(0, footer - 56);
    double art = fmin(172, fmax(0, bodyHeight - 70));
    double infoY = 44 + art + 4;
    l.mode = rect((width - 152) / 2, 6, 152, 32);
    l.body = rect(12, 44, width - 24, bodyHeight);
    l.cover = rect((width - art) / 2, 44, art, art);
    l.title = rect(16, infoY, width - 32, 22);
    l.artist = rect(16, infoY + 22, width - 32, 18);
    /* The 44pt quality hit area surrounds the small badge below the artist. */
    l.quality = rect((width - 208) / 2, infoY + 22, 208, 44);
    l.slider = rect(20, footer - 10, width - 40, 44);
    l.elapsed = rect(20, footer + 20, 52, 12);
    l.total = rect(width - 72, footer + 20, 52, 12);
    l.status = rect(74, footer + 20, width - 148, 12);
    l.previous = rect(width / 2 - 104, footer + 36, 52, 52);
    l.play = rect(width / 2 - 28, footer + 34, 56, 56);
    l.next = rect(width / 2 + 52, footer + 36, 52, 52);
    l.repeat = rect(width / 2 - 102, footer + 90, 44, 44);
    l.shuffle = rect(width / 2 - 22, footer + 90, 44, 44);
    l.favorite = rect(width / 2 + 58, footer + 90, 44, 44);
    return l;
}
double MCLyricCenterInset(double height, double rowHeight) {
    return fmax(0, (height - rowHeight) / 2);
}
double MCLyricCenterOffset(unsigned row, double height, double rowHeight) {
    return row * rowHeight - MCLyricCenterInset(height, rowHeight);
}
bool MCLyricCanFollow(double now, double resumeAfter, bool dragging, bool decelerating) {
    return !dragging && !decelerating && now >= resumeAfter;
}
double MCMiniDragOffset(double translation, double width, bool available) {
    if (!isfinite(translation) || !isfinite(width) || width <= 0) return 0;
    double limit = available ? width : width * .15;
    return fmax(-limit, fmin(limit, available ? translation : translation * .25));
}
int MCMiniDragDestination(double translation, double velocity, double width, bool previous, bool next) {
    if (!isfinite(translation) || !isfinite(velocity) || !isfinite(width) || width <= 0) return 0;
    bool far = fabs(translation) >= width * .28;
    bool flick = fabs(translation) >= 8 && fabs(velocity) >= 420 && translation * velocity > 0;
    if (!far && !flick) return 0;
    return translation < 0 ? (next ? -1 : 0) : (previous ? 1 : 0);
}
