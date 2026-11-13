#include "../Sources/Core/MCNowPlayingLayout.h"
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
static void checkScreen(double width, double screenHeight) {
    double height = screenHeight - 64; /* status + navigation, bottom bar hidden */
    MCNowPlayingLayout l = MCNowPlayingMakeLayout(width, height);
    MCPlayerRect controls[] = { l.quality, l.slider, l.previous, l.play, l.next,
                               l.repeat, l.shuffle, l.favorite };
    assert(inside(l.body, width, height));
    assert(l.body.y >= l.mode.y + l.mode.height + 6);
    assert(l.body.y + l.body.height < l.slider.y);
    assert(!overlaps(l.cover, l.title));
    assert(l.cover.width == l.cover.height);
    assert(l.quality.y + l.quality.height <= l.body.y + l.body.height);
    assert(l.title.y + l.title.height <= l.artist.y);
    for (unsigned i = 0; i < sizeof controls / sizeof *controls; i++) {
        assert(inside(controls[i], width, height));
        assert(controls[i].height >= 44 && controls[i].width >= 44);
        for (unsigned j = i + 1; j < sizeof controls / sizeof *controls; j++)
            assert(!overlaps(controls[i], controls[j]));
    }
    assert(l.favorite.y + l.favorite.height == height);
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
        assert(l.body.height >= 220 && l.body.height <= 250);
        assert(l.body.height >= 2 * 110);
        assert(l.body.height / 44 >= 5);
        assert(l.cover.width >= 156 && l.cover.width <= 172);
        assert(l.play.width == 56);
        printf("iPod 320x480: lyrics %.0fpt, cover %.0fpt, fixed play y=%.0fpt\n",
               l.body.height, l.cover.width, l.play.y + 64);
    }
}
int main(void) {
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
