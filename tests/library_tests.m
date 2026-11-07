#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <sqlite3.h>
#import <math.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

// Contract declarations keep the first test executable before production classes exist.
@interface MCLyrics : NSObject
+ (NSArray *)parse:(NSString *)text;
+ (NSInteger)indexAtTime:(NSTimeInterval)time lines:(NSArray *)lines;
@end
@interface MCLibrary : NSObject
- (id)initWithDatabasePath:(NSString *)path documentsPath:(NSString *)documents;
- (void)scan:(void (^)(NSUInteger, NSArray *))completion;
- (void)tracksMatching:(NSString *)query completion:(void (^)(NSArray *))completion;
- (void)favoriteTracks:(void (^)(NSArray *))completion;
- (void)recentTracks:(void (^)(NSArray *))completion;
- (void)setFavorite:(BOOL)value track:(NSDictionary *)track;
- (void)recordPlay:(NSDictionary *)track;
- (void)playlists:(void (^)(NSArray *))completion;
- (void)createPlaylist:(NSString *)name completion:(void (^)(NSString *))completion;
- (void)tracksInPlaylist:(NSString *)identifier completion:(void (^)(NSArray *))completion;
- (void)addTrack:(NSDictionary *)track toPlaylist:(NSString *)identifier;
- (void)removeTrack:(NSString *)trackID fromPlaylist:(NSString *)identifier;
- (void)deletePlaylist:(NSString *)identifier;
- (void)lyricsForTrack:(NSDictionary *)track completion:(void (^)(NSString *))completion;
@end
static NSUInteger checks;
#define CHECK(c, msg) do { checks++; if (!(c)) { fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,msg); exit(1); } } while(0)
static void Pump(BOOL (^done)(void)) { NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:12]; while (!done() && [limit timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]]; CHECK(done(), "async operation timed out"); }
static NSArray *Tracks(MCLibrary *lib, NSString *query) { __block NSArray *result=nil; [lib tracksMatching:query completion:^(NSArray *rows) { CHECK([NSThread isMainThread],"query callback on main"); result=rows; }]; CHECK(!result,"query returns asynchronously"); Pump(^BOOL{ return result!=nil; }); return result; }
static NSArray *Rows(MCLibrary *lib, int type, NSString *playlist) { __block NSArray *result=nil; void (^cb)(NSArray *)=^(NSArray *rows){ CHECK([NSThread isMainThread],"list callback on main"); result=rows; }; if(type==0)[lib favoriteTracks:cb]; else if(type==1)[lib recentTracks:cb]; else if(type==2)[lib playlists:cb]; else [lib tracksInPlaylist:playlist completion:cb]; Pump(^BOOL{return result!=nil;}); return result; }
static NSUInteger Scan(MCLibrary *lib, NSUInteger expectedErrors) { __block BOOL done=NO; __block NSUInteger count=0; [lib scan:^(NSUInteger imported,NSArray *errors){ CHECK([NSThread isMainThread],"scan callback on main"); if(errors.count!=expectedErrors) NSLog(@"Expected %lu errors, got %@",(unsigned long)expectedErrors,errors); CHECK([errors count]==expectedErrors,"scan error collection"); for(id error in errors) CHECK([error isKindOfClass:[NSError class]],"scan returns NSError entries"); count=imported; done=YES; }]; CHECK(!done,"scan returns immediately"); Pump(^BOOL{return done;}); return count; }
static void LE32(NSMutableData *d,uint32_t v){ uint8_t b[]={v,v>>8,v>>16,v>>24}; [d appendBytes:b length:4]; }
static NSData *WAV(void) { NSMutableData *d=[NSMutableData data]; [d appendBytes:"RIFF" length:4]; LE32(d,16036); [d appendBytes:"WAVEfmt " length:8]; LE32(d,16); uint8_t fmt[]={1,0,1,0,0x40,0x1f,0,0,0x80,0x3e,0,0,2,0,16,0}; [d appendBytes:fmt length:16]; [d appendBytes:"data" length:4]; LE32(d,16000); [d increaseLengthBy:16000]; return d; }
static void BE32(NSMutableData *d,uint32_t v){ uint8_t b[]={v>>24,v>>16,v>>8,v}; [d appendBytes:b length:4]; }
static NSData *Picture(void) { NSMutableData *pixels=[NSMutableData dataWithLength:300*150*4]; memset(pixels.mutableBytes,255,pixels.length); CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB(); CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels); CGImageRef image=CGImageCreate(300,150,8,32,300*4,color,(CGBitmapInfo)kCGImageAlphaLast,provider,NULL,NO,kCGRenderingIntentDefault); NSMutableData *result=[NSMutableData data]; CGImageDestinationRef dest=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)result,CFSTR("public.png"),1,NULL); CGImageDestinationAddImage(dest,image,NULL); CHECK(CGImageDestinationFinalize(dest),"make picture fixture");CFRelease(dest);CGImageRelease(image);CGDataProviderRelease(provider);CGColorSpaceRelease(color);return result; }
static void FLACBlock(NSMutableData *d,uint8_t type,NSData *payload,BOOL last){ uint32_t len=(uint32_t)payload.length; uint8_t h[]={type|(last?128:0),len>>16,len>>8,len}; [d appendBytes:h length:4]; [d appendData:payload]; }
static NSData *FLAC(NSString *title) { NSMutableData *d=[NSMutableData dataWithBytes:"fLaC" length:4]; uint8_t si[34]={0}; si[0]=0x10; si[2]=0x10; uint64_t packed=((uint64_t)44100<<44)|((uint64_t)1<<41)|((uint64_t)15<<36)|88200; for(int i=0;i<8;i++)si[10+i]=(packed>>(56-i*8))&255; FLACBlock(d,0,[NSData dataWithBytes:si length:34],NO); NSMutableData *c=[NSMutableData data]; LE32(c,4); [c appendBytes:"test" length:4]; NSArray *tags=@[[@"TITLE=" stringByAppendingString:title],@"ARTIST=暮雨",@"ALBUM=离线",@"UNUSED=ignored"]; LE32(c,(uint32_t)tags.count); for(NSString *tag in tags){NSData *b=[tag dataUsingEncoding:NSUTF8StringEncoding]; LE32(c,(uint32_t)b.length);[c appendData:b];} FLACBlock(d,4,c,NO); NSMutableData *pic=[NSMutableData data];BE32(pic,3);BE32(pic,9);[pic appendBytes:"image/png" length:9];BE32(pic,0);BE32(pic,300);BE32(pic,150);BE32(pic,24);BE32(pic,0);NSData *png=Picture();BE32(pic,(uint32_t)png.length);[pic appendData:png];FLACBlock(d,6,pic,YES); uint8_t frame[]={0xff,0xf8,0x69,0x18,0,0}; [d appendBytes:frame length:6]; return d; }
static void TestLyrics(void) { Class cls=NSClassFromString(@"MCLyrics"); CHECK(cls!=Nil,"MCLyrics implementation is present"); NSArray *a=[cls parse:@"[ar:歌手]\n[00:03.500][00:01.25]hello\n[offset:-250]\n[00:00.20]early\n[00:02]中\n[garbage]ignored\n[00:60]invalid"]; CHECK(a.count==4,"multiple time tags expand; metadata and invalid timestamps ignored"); CHECK(fabs([a[0][@"time"] doubleValue]+0.05)<0.00001,"global negative offset applied"); CHECK([a[1][@"text"] isEqual:@"hello"],"sorted lyric text"); CHECK(fabs([a[1][@"time"] doubleValue]-1)<0.00001,"fractional seconds respected"); CHECK([cls indexAtTime:-1 lines:a]==-1,"time before first returns -1"); CHECK([cls indexAtTime:1 lines:a]==1,"exact timestamp selects line"); CHECK([cls indexAtTime:99 lines:a]==3,"after last selects last"); CHECK([cls indexAtTime:0 lines:@[]]==-1,"empty lyric safe"); CHECK([[cls parse:nil] count]==0,"nil lyric safe"); }
static void TestUnknownDurationFLAC(void) {
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *documents=[root stringByAppendingPathComponent:@"Documents"];
    CHECK([[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:NULL],"create unknown-duration fixture directory");
    NSString *path=[documents stringByAppendingPathComponent:@"Unknown.flac"];
    NSMutableData *unknown=[FLAC(@"Unknown duration") mutableCopy];
    uint8_t *bytes=unknown.mutableBytes;
    // STREAMINFO begins at byte 8. Its low 36 packed bits encode total_samples.
    bytes[21]&=0xf0;memset(bytes+22,0,4);
    CHECK([unknown writeToFile:path atomically:YES],"write valid unknown-duration FLAC");
    MCLibrary *library=[[NSClassFromString(@"MCLibrary") alloc] initWithDatabasePath:[root stringByAppendingPathComponent:@"Library/music.sqlite"] documentsPath:documents];
    CHECK(Scan(library,0)==1,"valid FLAC with total_samples zero imports");
    NSDictionary *track=Tracks(library,@"Unknown duration").firstObject;
    CHECK(track!=nil && [track[@"duration"] doubleValue]==0,"unknown FLAC duration remains zero");
    CHECK([track[@"sampleRate"] integerValue]==44100 && [track[@"bitDepth"] integerValue]==16,"unknown duration preserves audio metadata");
    CHECK(Scan(library,0)==0,"unknown duration FLAC keeps normal duplicate scan behavior");
    NSArray *corruptions=@[@"zero rate",@"invalid depth",@"missing sync",@"reserved channel"];
    for(NSString *corruption in corruptions){
        NSString *brokenPath=[documents stringByAppendingPathComponent:[corruption stringByAppendingPathExtension:@"flac"]];
        NSMutableData *broken=[unknown mutableCopy];uint8_t *b=broken.mutableBytes;NSUInteger n=broken.length;
        if([corruption isEqual:@"zero rate"]){b[18]=0;b[19]=0;b[20]&=0x0f;}
        else if([corruption isEqual:@"invalid depth"]){b[20]&=0xfe;b[21]&=0x0f;}
        else if([corruption isEqual:@"missing sync"])b[n-6]=0;
        else b[n-3]=(b[n-3]&0x0f)|0xb0;
        CHECK([broken writeToFile:brokenPath atomically:YES],"write corrupt unknown-duration FLAC");
        CHECK(Scan(library,1)==0,"invalid FLAC still rejected with unknown duration");
        CHECK(Tracks(library,@"").count==1,"corrupt FLAC cannot enter library");
        [[NSFileManager defaultManager] removeItemAtPath:brokenPath error:NULL];
    }
    [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
}
int main(void) { @autoreleasepool { TestLyrics(); TestUnknownDurationFLAC(); Class cls=NSClassFromString(@"MCLibrary"); CHECK(cls!=Nil,"MCLibrary implementation is present"); NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]; NSString *docs=[root stringByAppendingPathComponent:@"Documents"]; NSString *nested=[docs stringByAppendingPathComponent:@"Nested"]; [[NSFileManager defaultManager] createDirectoryAtPath:nested withIntermediateDirectories:YES attributes:nil error:NULL]; NSString *db=[root stringByAppendingPathComponent:@"Library/music.sqlite"]; NSString *wav=[nested stringByAppendingPathComponent:@"100%_Tone.WAV"]; NSString *flac=[docs stringByAppendingPathComponent:@"Sample.flac"]; CHECK([WAV() writeToFile:wav atomically:YES],"write WAV fixture"); CHECK([FLAC(@"森林") writeToFile:flac atomically:YES],"write FLAC fixture"); [@"bad" writeToFile:[docs stringByAppendingPathComponent:@"bad.flac"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]; [@"bad" writeToFile:[docs stringByAppendingPathComponent:@"bad.mp3"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]; [@"not audio" writeToFile:[docs stringByAppendingPathComponent:@"ignore.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]; [@"[offset:200]\n[00:01]侧边歌词" writeToFile:[nested stringByAppendingPathComponent:@"100%_Tone.LRC"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
MCLibrary *lib=[[cls alloc] initWithDatabasePath:db documentsPath:docs]; CHECK(Scan(lib,2)==2,"valid native and FLAC imports"); NSArray *all=Tracks(lib,@""); CHECK(all.count==2,"only audio files imported recursively"); NSDictionary *ft=Tracks(lib,@"暮雨").firstObject; CHECK([ft[@"title"] isEqual:@"森林"],"FLAC Vorbis title and Unicode artist search"); CHECK(fabs([ft[@"duration"] doubleValue]-2)<0.001,"FLAC streaminfo duration"); CHECK([ft[@"sampleRate"] integerValue]==44100 && [ft[@"bitDepth"] integerValue]==16,"FLAC format metadata"); NSDictionary *wt=Tracks(lib,@"%_").firstObject; CHECK(wt!=nil && Tracks(lib,@"%_").count==1,"search treats SQL wildcard characters literally"); CHECK([wt[@"format"] isEqual:@"WAV"],"native extension normalized"); CHECK(fabs([wt[@"duration"] doubleValue]-1)<0.02,"native duration extracted"); NSString *art=ft[@"artwork"];CHECK(art.length>0 && ![art hasPrefix:docs],"embedded cover saved outside Documents");CGImageSourceRef cover=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:art],NULL);NSDictionary *props=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(cover,0,NULL));CFRelease(cover);CHECK([props[(__bridge NSString *)kCGImagePropertyPixelWidth] integerValue]==256 && [props[(__bridge NSString *)kCGImagePropertyPixelHeight] integerValue]==128,"cover thumbnail bounded to 256 pixels");NSString *stable=ft[@"id"]; CHECK([stable hasPrefix:@"local:"],"local identifier namespace"); CHECK(Scan(lib,2)==0,"unchanged tracks not reimported"); CHECK([Tracks(lib,@"森林").firstObject[@"id"] isEqual:stable],"scan keeps stable ID");[[NSFileManager defaultManager] removeItemAtPath:art error:NULL];CHECK(Scan(lib,2)==1,"evicted artwork cache regenerated");CHECK([[NSFileManager defaultManager] fileExistsAtPath:Tracks(lib,@"森林").firstObject[@"artwork"]],"regenerated artwork exists");
__block NSString *lyric=nil; [lib lyricsForTrack:wt completion:^(NSString *text){lyric=text?:@"";}]; Pump(^BOOL{return lyric!=nil;}); CHECK([lyric rangeOfString:@"侧边歌词"].location!=NSNotFound,"case insensitive matching LRC sidecar");
NSDictionary *online=@{@"id":@"9223372036854775808",@"title":@"Online",@"artist":@"Artist",@"album":@"Album",@"artwork":@"https://example.org/a.jpg",@"duration":@123}; [lib setFavorite:YES track:online]; [lib setFavorite:YES track:online]; [lib setFavorite:YES track:ft]; CHECK(Rows(lib,0,nil).count==2,"favorites persist online and local tracks without duplicates"); [lib recordPlay:online]; [lib recordPlay:ft]; [lib recordPlay:online]; NSArray *recent=Rows(lib,1,nil); CHECK(recent.count==2 && [recent.firstObject[@"id"] isEqual:online[@"id"]],"recent is distinct and newest first with full long ID");
__block NSString *playlist=nil; [lib createPlaylist:@"测试歌单" completion:^(NSString *identifier){playlist=identifier?:@"";}]; Pump(^BOOL{return playlist!=nil;}); CHECK(playlist.length>0,"create playlist produces identifier"); [lib addTrack:online toPlaylist:playlist]; [lib addTrack:ft toPlaylist:playlist]; [lib addTrack:online toPlaylist:playlist]; NSArray *items=Rows(lib,3,playlist); CHECK(items.count==2 && [items.firstObject[@"id"] isEqual:online[@"id"]],"playlist duplicate add preserves insertion order"); CHECK([Rows(lib,2,nil).firstObject[@"title"] isEqual:@"测试歌单"],"playlist catalog has name");
lib=nil; lib=[[cls alloc] initWithDatabasePath:db documentsPath:docs]; CHECK(Rows(lib,0,nil).count==2,"favorites survive reopen"); CHECK(Rows(lib,3,playlist).count==2,"playlist membership survives reopen"); CHECK([Rows(lib,1,nil).firstObject[@"id"] isEqual:online[@"id"]],"recent ordering survives reopen");
CHECK([FLAC(@"新森林") writeToFile:flac atomically:YES],"modify media file"); CHECK(Scan(lib,2)==1,"changed file reimports"); CHECK([Tracks(lib,@"新森林").firstObject[@"id"] isEqual:stable],"updated metadata keeps ID"); CHECK([Rows(lib,0,nil).lastObject[@"title"] isEqual:@"新森林"] || [Rows(lib,0,nil).firstObject[@"title"] isEqual:@"新森林"],"favorite reflects updated metadata");
[[NSFileManager defaultManager] removeItemAtPath:flac error:NULL]; CHECK(Scan(lib,2)==0,"deleted file scan finishes"); CHECK(Tracks(lib,@"").count==1,"deleted media removed"); CHECK(Rows(lib,0,nil).count==1,"deleted local favorite removed"); CHECK(Rows(lib,3,playlist).count==1,"deleted local playlist entry removed"); CHECK([Rows(lib,3,playlist).firstObject[@"id"] isEqual:online[@"id"]],"online playlist entry retained");
[lib removeTrack:online[@"id"] fromPlaylist:playlist]; CHECK(Rows(lib,3,playlist).count==0,"remove playlist member"); [lib deletePlaylist:playlist]; CHECK(Rows(lib,2,nil).count==0,"delete playlist"); [lib setFavorite:NO track:online]; CHECK(Rows(lib,0,nil).count==0,"unfavorite online track");
// A failed playlist mutation must not leave its newly inserted track behind.
__block BOOL mutationError=NO;id observer=[[NSNotificationCenter defaultCenter] addObserverForName:@"MCLibraryDidChangeNotification" object:lib queue:nil usingBlock:^(NSNotification *note){if([note.userInfo[@"errors"] count])mutationError=YES;}];[lib addTrack:@{@"id":@"18446744073709551615",@"title":@"Rollback"} toPlaylist:@"missing"];Rows(lib,2,nil);CHECK(mutationError,"mutation failure is observable");[[NSNotificationCenter defaultCenter] removeObserver:observer];sqlite3 *raw=NULL;CHECK(sqlite3_open([db fileSystemRepresentation],&raw)==SQLITE_OK,"inspect persisted rollback");sqlite3_stmt *stmt=NULL;sqlite3_prepare_v2(raw,"SELECT COUNT(*) FROM tracks WHERE id='18446744073709551615'",-1,&stmt,NULL);CHECK(sqlite3_step(stmt)==SQLITE_ROW && sqlite3_column_int(stmt,0)==0,"failed membership insert rolls back track insertion");sqlite3_finalize(stmt);sqlite3_close(raw);
// Replacing a scanned directory by a symlink must remove the old local paths.
NSString *outside=[root stringByAppendingPathComponent:@"Outside"];CHECK([[NSFileManager defaultManager] moveItemAtPath:nested toPath:outside error:NULL],"move scanned directory");CHECK([[NSFileManager defaultManager] createSymbolicLinkAtPath:nested withDestinationPath:outside error:NULL],"create external symlink");__block BOOL escapedDone=NO;[lib lyricsForTrack:wt completion:^(NSString *text){CHECK(text==nil,"symlink ancestor cannot expose lyrics outside Documents");escapedDone=YES;}];Pump(^BOOL{return escapedDone;});CHECK(Scan(lib,2)==0,"symlink folder is excluded");CHECK(Tracks(lib,@"").count==0,"old paths under replacement symlink removed");
// An oversized block is rejected from its header, without allocating its claimed body.
NSMutableData *evil=[NSMutableData dataWithBytes:"fLaC" length:4]; uint8_t h[]={0,0xff,0xff,0xff}; [evil appendBytes:h length:4]; [evil writeToFile:[docs stringByAppendingPathComponent:@"oversized.flac"] atomically:YES]; CHECK(Scan(lib,3)==0,"oversized FLAC metadata fails safely");
// Database initialization failure is surfaced by scan rather than aborting.
MCLibrary *broken=[[cls alloc] initWithDatabasePath:docs documentsPath:docs]; __block BOOL badDone=NO; [broken scan:^(NSUInteger n,NSArray *errors){CHECK(n==0 && errors.count>0,"database error collected");badDone=YES;}]; Pump(^BOOL{return badDone;});
[[NSFileManager defaultManager] removeItemAtPath:root error:NULL]; fprintf(stdout,"PASS library: %lu checks\n",(unsigned long)checks); } return 0; }
