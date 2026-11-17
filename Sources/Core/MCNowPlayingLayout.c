#include "MCNowPlayingLayout.h"
#include <math.h>

static MCPlayerRect rect(double x, double y, double w, double h) {
    return (MCPlayerRect){x, y, w, h};
}
MCPlayerRect MCMiniPlayerMakeFrame(double width, double height, double tabBarTop, bool tabBarHidden) {
    double bottom = tabBarHidden ? height : fmin(height, tabBarTop);
    return rect(0, bottom - 52, width, 52);
}
MCNowPlayingLayout MCNowPlayingMakeLayout(double width, double height) {
    MCNowPlayingLayout l = {0};
    double content = fmax(0, fmin(width - 32, 560));
    double left = (width - content) / 2, center = width / 2;
    double playSide = 60, bottomInset = 8, controlGap = 20;
    double playY = fmax(0, height - bottomInset - playSide);
    double footer = fmax(0, playY - controlGap - 44);
    double bodyTop = 52, bodyHeight = fmax(0, footer - 12 - bodyTop);
    double art = fmin(width >= 600 ? 480 : 420, fmin(content, bodyHeight));
    double artY = bodyTop + (bodyHeight - art) / 2;
    double controls = fmin(content, 360), edge = (width - controls) / 2;
    double step = (controls - 44) / 4;
    l.mode = rect(center - 96, 4, 192, 36);
    l.body = rect(left, bodyTop, content, bodyHeight);
    l.cover = rect(center - art / 2, artY, art, art);
    MCPlayerCoverLayout card = MCPlayerCoverMakeLayout(art, art, 1);
    l.title = card.title; l.artist = card.artist;
    l.quality = card.quality; l.favorite = card.favorite;
    MCPlayerRect *metadata[] = {&l.title, &l.artist, &l.quality, &l.favorite};
    for (unsigned i = 0; i < sizeof metadata / sizeof *metadata; i++) {
        metadata[i]->x += l.cover.x; metadata[i]->y += l.cover.y;
    }
    l.slider = rect(left + 52, footer, fmax(0, content - 104), 44);
    l.elapsed = rect(left, footer, 44, 44);
    l.total = rect(left + content - 44, footer, 44, 44);
    l.status = rect(left, footer + 44, content, 16);
    l.play = rect(center - playSide / 2, playY, playSide, playSide);
    double buttonY = l.play.y + 8;
    l.previous = rect(edge + step, buttonY, 44, 44);
    l.next = rect(edge + step * 3, buttonY, 44, 44);
    l.shuffle = rect(edge, buttonY, 44, 44);
    l.repeat = rect(width - edge - 44, buttonY, 44, 44);
    return l;
}
MCPlayerCoverLayout MCPlayerCoverMakeLayout(double width, double height, unsigned requestedTitleLines) {
    (void)requestedTitleLines;
    MCPlayerCoverLayout l = {0};
    bool tablet = width >= 400;
    double padding = tablet ? 16 : 12;
    double top = tablet ? 6 : 2;
    double bottom = tablet ? 12 : 8;
    double gap = tablet ? 3 : 2;
    double titleLine = tablet ? 25 : 20;
    double artistHeight = tablet ? 16 : 14, chipHeight = tablet ? 22 : 20;
    double panelHeight = top + titleLine + gap + artistHeight + gap + chipHeight + bottom;
    l.titleFontSize = tablet ? 20 : 16;
    l.artistFontSize = tablet ? 13 : 12;
    l.titleLines = 1;
    /* One fixed-size title row. Fade above the information so the scrim
       already protects the first glyphs, rather than starting behind them. */
    double fade = fmin(tablet ? 24 : 18, fmax(8, height * .4 - panelHeight));
    l.panel = rect(0, fmax(0, height - panelHeight - fade), width, fmin(height, panelHeight + fade));
    double textWidth = fmax(0, width - padding * 2 - 52);
    double titleY = height - panelHeight + top, titleHeight = titleLine;
    double artistY = titleY + titleHeight + gap;
    double qualityY = artistY + artistHeight + gap;
    l.title = rect(padding, titleY, textWidth, titleHeight);
    l.artist = rect(padding, artistY, textWidth, artistHeight);
    l.quality = rect(padding, qualityY, textWidth, chipHeight);
    l.favorite = rect(width - padding - 44, qualityY + chipHeight - 44, 44, 44);
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
