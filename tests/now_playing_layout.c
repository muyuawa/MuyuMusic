#include "../Sources/Core/MCNowPlayingLayout.h"
#include "../Sources/Core/MCDiscoverLayout.h"
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdio.h>

static bool inside(MCPlayerRect r, double w, double h) {
    return r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0 &&
           r.x + r.width <= w && r.y + r.height <= h;
}
static bool overlaps(MCPlayerRect a, MCPlayerRect b) {
    return a.x < b.x + b.width && b.x < a.x + a.width &&
           a.y < b.y + b.height && b.y < a.y + a.height;
}
static void checkCover(double side, unsigned requestedLines) {
    MCPlayerCoverLayout l = MCPlayerCoverMakeLayout(side, side, requestedLines);
    assert(l.panel.y >= side * .60 - .001);
    assert(l.panel.y + l.panel.height == side);
    if (side < 400) {
        double informationHeight = side - l.title.y + 2;
        assert(informationHeight >= 64 && informationHeight <= 72);
        assert(l.titleFontSize == 16 && l.artistFontSize == 12);
    }
    assert(l.titleLines == 1);
    assert(l.title.y - l.panel.y >= 10);
    if (side == 220) assert(l.title.width >= 8 * 16); /* both reported Chinese titles fit */
    MCPlayerRect metadata[] = { l.title, l.artist, l.quality, l.favorite };
    for (unsigned i = 0; i < sizeof metadata / sizeof *metadata; i++) {
        assert(inside(metadata[i], side, side));
        assert(metadata[i].y >= l.panel.y);
        for (unsigned j = i + 1; j < sizeof metadata / sizeof *metadata; j++)
            assert(!overlaps(metadata[i], metadata[j]));
    }
    assert(l.artist.y >= l.title.y + l.title.height + 2);
    assert(l.quality.y >= l.artist.y + l.artist.height + 2);
    assert(l.quality.height >= 20 && l.quality.height <= 22);
    assert(l.favorite.width == 44 && l.favorite.height == 44);
    /* The small chip expands to a 44pt hit target within the panel.
       Its hit target must remain below the separate title action. */
    double extra = 44 - l.quality.height;
    double bottom = fmin(extra / 2, side - l.quality.y - l.quality.height);
    MCPlayerRect hit = l.quality;
    hit.y -= extra - bottom; hit.height = 44;
    assert(inside(hit, side, side));
    assert(hit.y >= l.panel.y);
    assert(!overlaps(hit, l.title));
    assert(!overlaps(hit, l.favorite));
}
static void checkScreen(double width, double screenHeight) {
    double height = screenHeight - 64; /* status + navigation, bottom bar hidden */
    MCNowPlayingLayout l = MCNowPlayingMakeLayout(width, height);
    MCPlayerRect controls[] = { l.slider, l.previous, l.play, l.next,
                               l.repeat, l.shuffle, l.favorite };
    assert(inside(l.body, width, height));
    assert(l.body.y >= l.mode.y + l.mode.height + 4);
    assert(l.body.y + l.body.height <= l.slider.y - 12);
    assert(l.quality.y >= l.artist.y + l.artist.height);
    assert(l.cover.x <= l.title.x && l.cover.y <= l.title.y);
    assert(l.title.x + l.title.width <= l.cover.x + l.cover.width);
    assert(l.title.height >= 20);
    assert(l.quality.height >= 20 && l.quality.height <= 22);
    assert(!overlaps(l.quality, l.favorite));
    assert(l.quality.y + l.quality.height <= l.cover.y + l.cover.height);
    assert(l.favorite.x + l.favorite.width <= l.cover.x + l.cover.width);
    assert(l.favorite.y + l.favorite.height <= l.cover.y + l.cover.height);
    assert(l.mode.x + l.mode.width / 2 == width / 2);
    assert(l.mode.height == 36);
    assert(l.cover.width == l.cover.height);
    assert(l.title.y + l.title.height <= l.artist.y);
    assert(l.play.y - (l.slider.y + l.slider.height) >= 18);
    assert(l.play.y - (l.slider.y + l.slider.height) <= 22);
    for (unsigned i = 0; i < sizeof controls / sizeof *controls; i++) {
        assert(inside(controls[i], width, height));
        assert(controls[i].height >= 44 && controls[i].width >= 44);
        for (unsigned j = i + 1; j < sizeof controls / sizeof *controls; j++)
            assert(!overlaps(controls[i], controls[j]));
    }
    assert(l.play.width == 60 && l.play.height == 60);
    assert(l.play.y + l.play.height == height - 8);
    assert(l.favorite.y + l.favorite.height == l.quality.y + l.quality.height);
    /* Even first/last lines can sit at the center, thanks to equal end insets. */
    double inset = MCLyricCenterInset(l.body.height, 44);
    for (unsigned row = 0; row < 1000; row++) {
        double offset = MCLyricCenterOffset(row, l.body.height, 44);
        assert(fabs((row * 44 + 22 - offset) - l.body.height / 2) < .0001);
        assert(offset >= -inset);
        double lastOffset = (row + 1) * 44 + inset - l.body.height;
        assert(fabs(offset - lastOffset) < .0001);
    }
    if (width == 320 && screenHeight == 480) {
        assert(l.body.height >= 220);
        assert(l.body.height / 56 >= 3);
        assert(l.cover.width >= 216 && l.cover.width <= 224);
        printf("iPod 320x480: lyrics %.0fpt, cover %.0fpt, fixed play top=%.0fpt\n",
               l.body.height, l.cover.width, l.play.y);
    }
}
int main(void) {
    const double covers[] = {200, 216, 220, 288, 343, 382, 480};
    for (unsigned i = 0; i < sizeof covers / sizeof *covers; i++) {
        checkCover(covers[i], 1);
        checkCover(covers[i], 2);
    }
    const double widths[] = {320, 375, 768, 1024};
    for (unsigned i=0;i<sizeof widths/sizeof *widths;i++) {
        MCDiscoverLayout home = MCDiscoverMakeLayout(widths[i]);
        assert(inside(home.hero, widths[i], home.height));
        assert(inside(home.shelf, widths[i], home.height));
        assert(inside(home.heading, widths[i], home.height));
        assert(!overlaps(home.hero, home.shortcuts[0]));
        assert(!overlaps(home.shortcuts[0], home.shelfMode));
        assert(!overlaps(home.shelf, home.heading));
        for (unsigned j=0;j<4;j++) {
            assert(inside(home.shortcuts[j], widths[i], home.height));
            assert(home.shortcuts[j].width >= 44 && home.shortcuts[j].height >= 44);
            if (j) assert(!overlaps(home.shortcuts[j-1], home.shortcuts[j]));
        }
    }
    /* The tab bar can retain its old frame after Now Playing hides it.
       Browsing artists/albums above that controller must reach the bottom. */
    MCPlayerRect mini = MCMiniPlayerMakeFrame(320, 460, 411, true);
    assert(mini.y + mini.height == 460);
    assert(mini.x == 0 && mini.width == 320 && mini.height == 52);
    mini = MCMiniPlayerMakeFrame(320, 460, 411, false);
    assert(mini.y + mini.height == 411); /* tabs restored on return */
    mini = MCMiniPlayerMakeFrame(320, 460, 460, true);
    assert(mini.y + mini.height == 460); /* offscreen tab bar */
    mini = MCMiniPlayerMakeFrame(320, 548, 499, true);
    assert(mini.y + mini.height == 548);
    checkScreen(320, 480);
    checkScreen(320, 460); /* transient taller status bar */
    checkScreen(320, 568);
    checkScreen(375, 667);
    checkScreen(414, 736);
    checkScreen(768, 1024);
    checkScreen(1024, 768);
    assert(!MCLyricCanFollow(10, DBL_MAX, true, false));
    assert(!MCLyricCanFollow(10, 0, false, true));
    assert(!MCLyricCanFollow(12.9, 13, false, false));
    assert(MCLyricCanFollow(13, 13, false, false));
    assert(MCLyricCanFollow(14, 13, false, false));
    assert(MCLyricCanFollow(10, 0, false, false)); /* explicit seek/mode change */
    assert(MCLyricCenterInset(20, 44) == 0);
    assert(MCMiniDragOffset(-40, 188, true) == -40);
    assert(MCMiniDragOffset(999, 188, true) == 188);
    assert(MCMiniDragOffset(-80, 188, false) == -20);
    assert(MCMiniDragOffset(999, 188, false) <= 188 * .15);
    assert(MCMiniDragOffset(NAN, 188, true) == 0);
    assert(MCMiniDragDestination(-52, 0, 188, true, true) == 0);
    assert(MCMiniDragDestination(-53, 0, 188, true, true) == -1);
    assert(MCMiniDragDestination(53, 0, 188, true, true) == 1);
    assert(MCMiniDragDestination(-10, -500, 188, true, true) == -1);
    assert(MCMiniDragDestination(-10, 500, 188, true, true) == 0);
    assert(MCMiniDragDestination(-3, -1000, 188, true, true) == 0);
    assert(MCMiniDragDestination(-100, -500, 188, true, false) == 0);
    assert(MCMiniDragDestination(100, 500, 188, false, true) == 0);
    assert(MCMiniDragDestination(NAN, 0, 188, true, true) == 0);
    assert(MCMiniDragDestination(100, 500, 0, true, true) == 0);
    puts("Now-playing layout and lyric follow checks passed");
}
