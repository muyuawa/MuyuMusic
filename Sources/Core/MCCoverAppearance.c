#include "MCCoverAppearance.h"
#include <math.h>
#include <string.h>

static double clamp(double v, double lo, double hi) { return fmax(lo, fmin(v, hi)); }
static double smooth(double t) { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); }
static double brightness(MCColor c) { return .2126 * c.r + .7152 * c.g + .0722 * c.b; }
static MCColor pixel(const uint8_t *p, MCColor fallback) {
    double a = p[3] / 255.;
    return (MCColor){p[0] / 255. + fallback.r * (1-a), p[1] / 255. + fallback.g * (1-a), p[2] / 255. + fallback.b * (1-a)};
}
static double linear(double v) { return v <= .04045 ? v / 12.92 : pow((v + .055) / 1.055, 2.4); }
static double encoded(double v) { v = clamp(v, 0, 1); return v <= .0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - .055; }
static void toLab(MCCoverColorNode *n) {
    double r = linear(n->color.r), g = linear(n->color.g), b = linear(n->color.b);
    double l = cbrt(.4122214708*r + .5363325363*g + .0514459929*b);
    double m = cbrt(.2119034982*r + .6806995451*g + .1073969566*b);
    double s = cbrt(.0883024619*r + .2817188376*g + .6299787005*b);
    n->lightness = .2104542553*l + .7936177850*m - .0040720468*s;
    n->chromaA = 1.9779984951*l - 2.4285922050*m + .4505937099*s;
    n->chromaB = .0259040371*l + .7827717662*m - .8086757660*s;
}
static MCColor fromLab(double lightness, double a, double b) {
    MCColor rgb = {0};
    /* Keep hue while reducing chroma only when the corrected color leaves
       sRGB. Convex spatial interpolation cannot overshoot node lightness. */
    for (unsigned i = 0; i < 16; i++) {
        double l = lightness + .3963377774*a + .2158037573*b;
        double m = lightness - .1055613458*a - .0638541728*b;
        double s = lightness - .0894841775*a - 1.2914855480*b;
        l *= l*l; m *= m*m; s *= s*s;
        rgb = (MCColor){4.0767416621*l - 3.3077115913*m + .2309699292*s,
            -1.2684380046*l + 2.6097574011*m - .3413193965*s,
            -.0041960863*l - .7034186147*m + 1.7076147010*s};
        if (rgb.r >= -.00001 && rgb.g >= -.00001 && rgb.b >= -.00001 &&
            rgb.r <= 1.00001 && rgb.g <= 1.00001 && rgb.b <= 1.00001) break;
        a *= .8; b *= .8;
    }
    return (MCColor){encoded(rgb.r), encoded(rgb.g), encoded(rgb.b)};
}
static double percentile(const unsigned h[256], unsigned count, double fraction) {
    unsigned sum = 0;
    for (unsigned i = 0; i < 256; i++) { sum += h[i]; if (sum > count * fraction) return i / 255.; }
    return 0;
}
typedef struct { MCColor middle, mean; double variance, spread, edges, confidence; } MCStatistics;
static MCStatistics statistics(const uint8_t *rgba, unsigned width, unsigned height, size_t stride,
                              MCColor fallback, double left, double top, double right, double bottom) {
    unsigned hist[4][256] = {{0}}, count = 0, edges = 0;
    double light = 0, squared = 0;
    unsigned x0 = (unsigned)clamp(floor(left * width), 0, width-1), x1 = (unsigned)clamp(ceil(right * width), x0+1, width);
    unsigned y0 = (unsigned)clamp(floor(top * height), 0, height-1), y1 = (unsigned)clamp(ceil(bottom * height), y0+1, height);
    for (unsigned y = y0; y < y1; y++) for (unsigned x = x0; x < x1; x++) {
        MCColor c = pixel(rgba + y*stride + x*4, fallback);
        double values[] = {c.r, c.g, c.b, brightness(c)};
        for (unsigned i = 0; i < 4; i++) hist[i][(unsigned)round(clamp(values[i],0,1)*255)]++;
        double b = values[3]; light += b; squared += b*b;
        bool edge = x > x0 && fabs(b - brightness(pixel(rgba+y*stride+(x-1)*4,fallback))) > .16;
        if (y > y0 && fabs(b - brightness(pixel(rgba+(y-1)*stride+x*4,fallback))) > .16) edge = true;
        if (edge) edges++; count++;
    }
    MCStatistics result = {0};
    double low[3], high[3], sum[3] = {0}; unsigned reliable = 0;
    double *middle[] = {&result.middle.r, &result.middle.g, &result.middle.b};
    for (unsigned i = 0; i < 3; i++) {
        *middle[i] = percentile(hist[i],count,.5); low[i] = percentile(hist[i],count,.1); high[i] = percentile(hist[i],count,.9);
    }
    /* Winsorized means suppress small logos and saturated outliers without
       choosing a single most frequent RGB triplet. Neutral pixels remain. */
    for (unsigned y = y0; y < y1; y++) for (unsigned x = x0; x < x1; x++) {
        MCColor c = pixel(rgba+y*stride+x*4,fallback); double values[] = {c.r,c.g,c.b}; bool accepted = true;
        for (unsigned i = 0; i < 3; i++) { sum[i] += clamp(values[i],low[i],high[i]); accepted &= values[i] >= low[i] && values[i] <= high[i]; }
        if (accepted) reliable++;
    }
    result.mean = (MCColor){sum[0]/count,sum[1]/count,sum[2]/count};
    result.variance = fmax(0,squared/count-(light/count)*(light/count));
    result.spread = percentile(hist[3],count,.95)-percentile(hist[3],count,.05);
    result.edges = edges/(double)count; result.confidence = reliable/(double)count;
    return result;
}
static void weights(const MCCoverAppearance *a, double x, double y, unsigned indices[4], double w[4]) {
    double gx = clamp(x,0,1)*(a->columns-1), gy = clamp(y,0,1)*(a->rows-1);
    unsigned col = (unsigned)fmin(floor(gx),a->columns-2), row = (unsigned)fmin(floor(gy),a->rows-2);
    double tx = smooth(gx-col), ty = smooth(gy-row);
    indices[0] = row*a->columns+col; indices[1] = indices[0]+1;
    indices[2] = indices[0]+a->columns; indices[3] = indices[2]+1;
    w[0] = (1-tx)*(1-ty); w[1] = tx*(1-ty); w[2] = (1-tx)*ty; w[3] = tx*ty;
}
static MCColor fieldColor(const MCCoverAppearance *a, double x, double y) {
    if (a->columns < 2 || a->columns > MCCoverColorColumns || a->rows != MCCoverColorRows) return a->tint;
    unsigned indices[4]; double w[4], l = 0, ca = 0, cb = 0; weights(a,x,y,indices,w);
    for (unsigned i = 0; i < 4; i++) { MCCoverColorNode n = a->nodes[indices[i]]; l += n.lightness*w[i]; ca += n.chromaA*w[i]; cb += n.chromaB*w[i]; }
    return fromLab(l,ca,cb);
}
static double strength(const MCCoverAppearance *a, double x, double y) {
    if (a->columns < 2 || a->columns > MCCoverColorColumns || a->rows != MCCoverColorRows) return a->opacity[6];
    unsigned indices[4]; double w[4], value = 0; weights(a,x,y,indices,w);
    for (unsigned i = 0; i < 4; i++) value += a->nodes[indices[i]].strength*w[i];
    return value;
}
static double fieldAlpha(const MCCoverAppearance *a, double x, double y) {
    y = clamp(y,0,1); double end = clamp(a->fadeEnd,.05,.65);
    double hold = .02*smooth((y-end)/(1-end));
    return clamp(strength(a,x,y)*smooth(y/end)+hold,0,.98);
}
MCColor MCCoverGradientColor(MCCoverAppearance a, double x, double y) { return fieldColor(&a,x,y); }
double MCCoverGradientAlpha(MCCoverAppearance a, double x, double y) { return fieldAlpha(&a,x,y); }
double MCCoverGradientPosition(MCCoverAppearance a, unsigned index) {
    if (index >= MCCoverGradientStops-1) return 1;
    double end = clamp(a.fadeEnd,.05,.65);
    return index <= 6 ? end*index/6. : end+(1-end)*(index-6)/6.;
}
double MCCoverGradientOpacity(MCCoverAppearance a, double position) { return fieldAlpha(&a,.5,position); }
static void updateCenter(MCCoverAppearance *a) {
    a->tint = fieldColor(a,.5,1);
    for (unsigned i = 0; i < MCCoverGradientStops; i++) a->opacity[i] = fieldAlpha(a,.5,MCCoverGradientPosition(*a,i));
}
MCCoverAppearance MCCoverAppearanceFallback(MCColor background) {
    MCCoverAppearance a = {0}; a.tint = background; a.foreground = MCColorForeground(background); a.fadeEnd = .25;
    a.minimumContrast = MCColorContrast(background,a.foreground); a.readableFraction = 1; a.columns = 5; a.rows = 3;
    for (unsigned i = 0; i < a.columns*a.rows; i++) { a.nodes[i].color = background; toLab(&a.nodes[i]); a.nodes[i].strength = .06; a.nodes[i].confidence = 1; }
    updateCenter(&a); return a;
}
static bool contains(MCPlayerRect r, double x, double y) { return x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height; }
static void contrast(const uint8_t *rgba, unsigned width, unsigned height, size_t stride,
                     double cardWidth, double cardHeight, MCPlayerCoverLayout layout,
                     MCColor fallback, MCCoverAppearance *a, bool repair) {
    MCPlayerRect favorite = layout.favorite; favorite.x += 10; favorite.y += 10; favorite.width -= 20; favorite.height -= 20;
    double total = 0, readable = 0, minimum = 21, required[MCCoverColorColumns*MCCoverColorRows];
    for (unsigned i = 0; i < a->columns*a->rows; i++) required[i] = a->nodes[i].strength;
    for (unsigned y = 0; y < height; y++) for (unsigned x = 0; x < width; x++) {
        double px = (x+.5)*cardWidth/width, py = (y+.5)*cardHeight/height;
        double weight = contains(layout.title,px,py) ? 3 : contains(layout.artist,px,py) ? 2 : contains(favorite,px,py) ? 1 : 0;
        if (!weight) continue;
        double nx = px/cardWidth, ny = (py-layout.panel.y)/layout.panel.height;
        MCColor source = pixel(rgba+y*stride+x*4,fallback), tint = fieldColor(a,nx,ny);
        double alpha = fieldAlpha(a,nx,ny);
        double ratio = MCColorContrast(MCColorBlend(source,tint,alpha),a->foreground);
        minimum = fmin(minimum,ratio); total += weight; if (ratio >= 4.5) readable += weight;
        if (!repair || ratio >= 4.65) continue;
        double lo = alpha, hi = .98;
        for (unsigned step = 0; step < 8; step++) {
            double candidate = (lo+hi)/2;
            if (MCColorContrast(MCColorBlend(source,tint,candidate),a->foreground) >= 4.65) hi = candidate; else lo = candidate;
        }
        double end = clamp(a->fadeEnd,.05,.65), ramp = smooth(ny/end);
        double needed = clamp((hi-.02*smooth((ny-end)/(1-end)))/fmax(.001,ramp),0,.96);
        unsigned indices[4]; double w[4]; weights(a,nx,ny,indices,w);
        for (unsigned i = 0; i < 4; i++) if (w[i] > .0001) required[indices[i]] = fmax(required[indices[i]],needed);
    }
    if (repair) for (unsigned i = 0; i < a->columns*a->rows; i++) a->nodes[i].strength = required[i];
    a->minimumContrast = minimum; a->readableFraction = total ? readable/total : 1; a->needsTextOutline = minimum < 4.5;
}
bool MCCoverAppearanceMake(const uint8_t *rgba, unsigned width, unsigned height,
                          size_t stride, double cardWidth, double cardHeight,
                          MCPlayerCoverLayout layout, MCColor fallback, MCCoverAppearance *out) {
    if (!rgba || !out || !width || !height || width > 64 || height > 64 || stride < width*4 ||
        !isfinite(cardWidth) || !isfinite(cardHeight) || cardWidth <= 0 || cardHeight <= 0 ||
        !isfinite(layout.panel.y) || !isfinite(layout.panel.height) || layout.panel.height <= 0) return false;
    double top = clamp(layout.panel.y/cardHeight,0,1);
    MCStatistics overall = statistics(rgba,width,height,stride,fallback,0,clamp((layout.title.y-2)/cardHeight,top,1),1,1);
    MCColor base = MCColorBlend(overall.middle,overall.mean,.3);
    bool paper = brightness(overall.middle) > .75 && fmax(overall.middle.r,fmax(overall.middle.g,overall.middle.b))-
        fmin(overall.middle.r,fmin(overall.middle.g,overall.middle.b)) < .12;
    if (paper) base = MCColorBlend(overall.middle,overall.mean,.1);
    MCCoverAppearance a = {0}; a.foreground = MCColorForeground(base); a.columns = cardWidth >= 300 ? 7 : 5; a.rows = 3;
    a.fadeEnd = clamp((layout.title.y-layout.panel.y)/layout.panel.height,.05,.65);
    for (unsigned row = 0; row < a.rows; row++) for (unsigned col = 0; col < a.columns; col++) {
        double x = col/(double)(a.columns-1), y = top+(1-top)*row/(a.rows-1);
        double rx = .85/(a.columns-1), ry = (1-top)*.38;
        MCStatistics local = statistics(rgba,width,height,stride,fallback,fmax(0,x-rx),fmax(top,y-ry),fmin(1,x+rx),fmin(1,y+ry));
        MCCoverColorNode *n = &a.nodes[row*a.columns+col];
        n->color = MCColorBlend(local.middle,local.mean,.35);
        if (paper) {
            /* Dark isolated lettering must not turn light paper into a dark
               node. Retain small genuine paper tint differences. */
            n->color = brightness(local.middle) < .65 ? MCColorBlend(base,n->color,.08) : MCColorBlend(local.middle,local.mean,.08);
        }
        n->brightness = brightness(local.mean); double high = fmax(n->color.r,fmax(n->color.g,n->color.b));
        n->saturation = high ? (high-fmin(n->color.r,fmin(n->color.g,n->color.b)))/high : 0;
        n->variation = local.variance; n->confidence = local.confidence;
        n->strength = clamp((a.foreground.r == 0 ? .035 : .10)+local.variance*.3,.035,.18);
        if (local.spread > .18 && (local.edges > .015 || local.variance > .05))
            n->strength = fmax(n->strength,paper ? .86 : .50+.32*clamp((local.spread-.18)/.52,0,1));
        toLab(n);
    }
    /* Smooth adjacent nodes without collapsing their large-scale color
       arrangement into a single average. Work in perceptual coordinates. */
    MCCoverColorNode original[MCCoverColorColumns*MCCoverColorRows]; memcpy(original,a.nodes,sizeof original);
    for (unsigned row = 0; row < a.rows; row++) for (unsigned col = 0; col < a.columns; col++) {
        unsigned index = row*a.columns+col, neighbors[4], count = 0;
        if (col) neighbors[count++] = index-1; if (col+1<a.columns) neighbors[count++] = index+1;
        if (row) neighbors[count++] = index-a.columns; if (row+1<a.rows) neighbors[count++] = index+a.columns;
        double l = 0, ca = 0, cb = 0;
        for (unsigned i = 0; i < count; i++) { l += original[neighbors[i]].lightness; ca += original[neighbors[i]].chromaA; cb += original[neighbors[i]].chromaB; }
        MCCoverColorNode *n = &a.nodes[index]; n->lightness = .78*n->lightness+.22*l/count;
        n->chromaA = .78*n->chromaA+.22*ca/count; n->chromaB = .78*n->chromaB+.22*cb/count;
        n->color = fromLab(n->lightness,n->chromaA,n->chromaB);
        for (unsigned step = 0; step < 40 && MCColorContrast(n->color,a.foreground) < 7; step++) {
            n->lightness = clamp(n->lightness+(a.foreground.r == 0 ? .015 : -.015),.08,.98);
            n->color = fromLab(n->lightness,n->chromaA,n->chromaB);
        }
        /* Store the gamut-mapped chroma actually used by the field. */
        toLab(n);
    }
    for (unsigned pass = 0; pass < 3; pass++) contrast(rgba,width,height,stride,cardWidth,cardHeight,layout,fallback,&a,true);
    contrast(rgba,width,height,stride,cardWidth,cardHeight,layout,fallback,&a,false);
    updateCenter(&a); *out = a; return true;
}
bool MCCoverGradientRenderRGBA(MCCoverAppearance a, uint8_t *rgba, unsigned width, unsigned height, size_t stride) {
    if (!rgba || width < 2 || height < 2 || width > 256 || height > 128 || stride < width*4) return false;
    for (unsigned y = 0; y < height; y++) for (unsigned x = 0; x < width; x++) {
        double nx = x/(double)(width-1), ny = y/(double)(height-1);
        MCColor c = fieldColor(&a,nx,ny); double alpha = fieldAlpha(&a,nx,ny);
        uint8_t *p = rgba+y*stride+x*4;
        p[0] = (uint8_t)round(clamp(c.r,0,1)*alpha*255); p[1] = (uint8_t)round(clamp(c.g,0,1)*alpha*255);
        p[2] = (uint8_t)round(clamp(c.b,0,1)*alpha*255); p[3] = (uint8_t)round(alpha*255);
    }
    return true;
}
