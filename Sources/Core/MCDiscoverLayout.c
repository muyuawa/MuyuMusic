#include "MCDiscoverLayout.h"
#include <math.h>
MCDiscoverLayout MCDiscoverMakeLayout(double width) {
    MCDiscoverLayout l = {0};
    double usable = fmin(width - 32, 960), left = (width - usable) / 2;
    bool wide = usable >= 600;
    double hero = wide ? 136 : 120;
    l.hero = (MCPlayerRect){left, 8, usable, hero};
    double top = hero + 20, item = (usable - 24) / 4;
    if (wide) {
        l.hero.width = (usable - 16) * .58;
        double x = left + l.hero.width + 16;
        item = (usable - l.hero.width - 24) / 2;
        for (unsigned i=0;i<4;i++)
            l.shortcuts[i] = (MCPlayerRect){x + (i % 2) * (item + 8), 12 + (i / 2) * 68, item, 60};
    } else {
        for (unsigned i=0;i<4;i++)
            l.shortcuts[i] = (MCPlayerRect){left + i * (item + 8), top, item, 60};
        top += 72;
    }
    l.shelfMode = (MCPlayerRect){left, top + 6, fmin(200, usable - 88), 32};
    l.shelfMore = (MCPlayerRect){left + usable - 88, top, 88, 44};
    top += 48;
    l.tileWidth = wide ? 132 : 96;
    l.shelf = (MCPlayerRect){left, top, usable, l.tileWidth + 38};
    top += l.shelf.height + 8;
    l.heading = (MCPlayerRect){left, top, usable, 44};
    l.height = top + 48;
    return l;
}
