#import <Foundation/Foundation.h>
#import "MCEAPI.h"
static unsigned failures;
#define CHECK(...) do { if (!(__VA_ARGS__)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#__VA_ARGS__); failures++; } } while(0)
int main(void) { @autoreleasepool {
    NSError *error = nil;
    NSString *vector = @"9B1595479B79266065903BA79E9883029338432CD7D98D1A3626E997A2C5312129ED931D53578407823694513C82DFE783E53E2CD39B11979F4E416A38B2402FAE001B0347412E37D1C2D692A67BFC19D61CD3C5D92A93172497F21CC73427F1";
    CHECK([[MCEAPI encryptedParamsForPath:@"/api/song/lyric" JSON:@"{\"id\":\"347230\"}" error:&error] isEqual:vector]);
    CHECK(error == nil);
    NSDictionary *decoded = [MCEAPI decodeResponse:[@"{\"code\":200,\"id\":9223372036854775807}" dataUsingEncoding:NSUTF8StringEncoding] error:&error];
    CHECK([[MCEAPI identifier:[decoded objectForKey:@"id"]] isEqual:@"9223372036854775807"]);
    CHECK([MCEAPI identifier:@"local:123"] == nil);
    CHECK([MCEAPI identifier:@"123\nInjected"] == nil);
    NSDictionary *track = [MCEAPI track:@{@"id":@5000000001LL,@"name":@"歌",@"dt":@123456,@"ar":@[@{@"id":@9000000001LL,@"name":@"Artist"}],@"al":@{@"id":@6000000001LL,@"name":@"Album",@"picUrl":@"http://p1.music.126.net/a.jpg"}}];
    CHECK([[track objectForKey:@"id"] isEqual:@"5000000001"]);
    CHECK([[track objectForKey:@"artistID"] isEqual:@"9000000001"]);
    CHECK(fabs([[track objectForKey:@"duration"] doubleValue] - 123.456) < 0.001);
    CHECK([[track objectForKey:@"artwork"] hasPrefix:@"https://"]);
    CHECK([[MCEAPI catalogItem:@{@"id":@1,@"name":@"Mix",@"coverImgUrl":@"https://p1.music.126.net/p.jpg",@"creator":@{@"nickname":@"A"}}][@"subtitle"] isEqual:@"A"]);
    error = nil;
    CHECK([MCEAPI playableURL:@{@"code":@200,@"url":@"https://m801.music.126.net/music.mp3",@"type":@"mp3",@"freeTrialInfo":@{@"start":@0,@"end":@30}} error:&error] == nil);
    CHECK(error != nil);
    error = nil;
    NSDictionary *play = [MCEAPI playableURL:@{@"code":@200,@"url":@"http://m801.music.126.net/music.flac",@"type":@"flac",@"br":@960000,@"size":@40000000,@"expi":@1200,@"freeTrialInfo":[NSNull null]} error:&error];
    CHECK([[play objectForKey:@"url"] hasPrefix:@"https://"]);
    CHECK([[play objectForKey:@"format"] isEqual:@"flac"]);
    CHECK([play objectForKey:@"bitDepth"] == nil); /* Never invent precision from requested quality. */
    CHECK([play objectForKey:@"expires"] != nil);
    error = nil;
    CHECK([MCEAPI playableURL:@{@"url":@"https://untrusted.example/song",@"code":@200} error:&error] == nil);
    CHECK([MCEAPI isAPIHost:@"interface3.music.163.com"]);
    CHECK(![MCEAPI isAPIHost:@"music.163.com.evil.example"]);
    CHECK(![MCEAPI isAPIHost:@"m801.music.126.net"]);
    error = nil;
    CHECK([MCEAPI decodeResponse:[@"[]" dataUsingEncoding:NSUTF8StringEncoding] error:&error] == nil && error != nil);
    error = nil;
    CHECK([MCEAPI decodeResponse:[@"{\"code\":null}" dataUsingEncoding:NSUTF8StringEncoding] error:&error] == nil && error != nil);
    error = nil;
    CHECK([MCEAPI playableURL:@{@"url":@"https://m801.music.126.net/song.mp3",@"code":[NSNull null]} error:&error] == nil && error != nil);
    fprintf(stdout,"network_tests: %u failures\n",failures);
    return failures ? 1 : 0;
} }
