#import <AppKit/AppKit.h>
static BOOL render(NSImage *source, NSString *output, NSInteger width, NSInteger height, BOOL launch) {
 NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
 [NSGraphicsContext saveGraphicsState];
 [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
 [[NSColor colorWithSRGBRed:246.0/255 green:247.0/255 blue:1 alpha:1] setFill]; NSRectFill(NSMakeRect(0,0,width,height));
 CGFloat size=launch?width*.45:width;
 NSRect frame=NSMakeRect((width-size)/2,(height-size)/2,size,size);
 if(launch)[[NSBezierPath bezierPathWithRoundedRect:frame xRadius:size/6 yRadius:size/6] addClip];
 [source drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
 [NSGraphicsContext restoreGraphicsState];
 NSBitmapImageRep *opaque=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
 for(NSInteger y=0;y<height;y++)for(NSInteger x=0;x<width;x++){
  NSUInteger pixel[4]={0}; [bitmap getPixel:pixel atX:x y:y]; [opaque setPixel:pixel atX:x y:y];
 }
 return [[opaque representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:output atomically:YES];
}
int main(int argc,char **argv) { @autoreleasepool {
 if(argc!=3)return 64;
 NSImage *source=[[NSImage alloc] initWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
 if(!source)return 65;
 NSString *root=[NSString stringWithUTF8String:argv[2]];
 NSArray *assets=@[@[@"Icon.png",@60,@60,@NO],@[@"Icon@2x.png",@120,@120,@NO],@[@"Icon-Small.png",@29,@29,@NO],@[@"Icon-Small@2x.png",@58,@58,@NO],@[@"Icon-Spotlight.png",@40,@40,@NO],@[@"Icon-Spotlight@2x.png",@80,@80,@NO],@[@"AppPlaceholder.png",@256,@256,@NO],@[@"Default.png",@320,@480,@YES],@[@"Default@2x.png",@640,@960,@YES],@[@"Default-568h@2x.png",@640,@1136,@YES]];
 for(NSArray *asset in assets)if(!render(source,[root stringByAppendingPathComponent:asset[0]],[asset[1] integerValue],[asset[2] integerValue],[asset[3] boolValue]))return 1;
 puts("Application, placeholder and launch artwork rendered");
 return 0;
} }
