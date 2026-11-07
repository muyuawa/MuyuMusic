#include "MCColor.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    MCColor c;
    assert(MCColorParse("#365EA8", &c));
    assert(fabs(c.r - 54.0/255)<0.001);
    assert(MCColorParse("b44d79", &c));
    assert(!MCColorParse("#GG0000", &c));
    assert(!MCColorParse("#1234567", &c));
    assert(!MCColorParse("#123", &c));
    assert(!MCColorParse(NULL, &c));
    for (unsigned i=0;i<0xFFFFFF;i+=7919) {
        MCColor bg = {(i>>16)/255.0, ((i>>8)&255)/255.0, (i&255)/255.0};
        assert(MCColorContrast(bg, MCColorForeground(bg)) >= 4.5);
        MCColor light={1,1,1},dark={36.0/255,44.0/255,60.0/255};
        assert(MCColorContrast(MCColorAccent(bg,false),light)>=4.5);
        assert(MCColorContrast(MCColorAccent(bg,true),dark)>=4.5);
        MCColor tintedLight=MCColorBlend((MCColor){246.0/255,247.0/255,1},bg,.12);
        MCColor tintedDark=MCColorBlend(dark,bg,.12);
        MCColor primaryLight=MCColorReadableAccent(bg,false,tintedLight);
        MCColor primaryDark=MCColorReadableAccent(bg,true,tintedDark);
        assert(MCColorContrast(primaryLight,tintedLight)>=4.5);
        assert(MCColorContrast(primaryDark,tintedDark)>=4.5);
        assert(MCColorContrast(primaryLight,MCColorForeground(primaryLight))>=4.5);
        assert(MCColorContrast(primaryDark,MCColorForeground(primaryDark))>=4.5);
    }
    uint8_t pixels[16*4];
    for (unsigned i=0;i<16;i++) {
        pixels[i*4]=i<10?255:30; pixels[i*4+1]=i<10?255:80;
        pixels[i*4+2]=i<10?255:200; pixels[i*4+3]=255;
    }
    assert(MCColorArtwork(pixels,16,1,64,&c));
    assert(c.b>.7 && c.r<.2); /* ignore white border; keep blue art */
    for (unsigned i=0;i<16;i++) {
        pixels[i*4]=200; pixels[i*4+1]=40; pixels[i*4+2]=60;
    }
    assert(MCColorArtwork(pixels,16,1,64,&c));
    assert(c.r>.7 && c.b<.3); /* next cover changes hue */
    for (unsigned i=0;i<16*4;i++) pixels[i]=255;
    assert(!MCColorArtwork(pixels,16,1,64,&c)); /* plain white: manual fallback */
    for (unsigned i=0;i<16;i++) pixels[i*4+3]=0;
    assert(!MCColorArtwork(pixels,16,1,64,&c));
    assert(!MCColorArtwork(NULL,16,1,64,&c));
    assert(!MCColorArtwork(pixels,16,1,10,&c));
    puts("theme: strict HEX and 2,119 contrast cases passed");
    puts("artwork theme: dominant hue, white/transparent fallback and tinted contrast passed");
}
