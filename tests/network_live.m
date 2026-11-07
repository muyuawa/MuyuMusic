#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "MCAPI.h"
static int pending=0, failures=0;
static void done(NSString *name,id result,NSError *error,BOOL denialAllowed) {
    if(![NSThread isMainThread]) { fprintf(stderr,"FAIL %s callback not main\n",[name UTF8String]);failures++; }
    if(error) { fprintf(stdout,"%s: %s domain=%s code=%ld\n",[name UTF8String],denialAllowed ? "service denial/network error (reported)" : "FAIL",[error.domain UTF8String],(long)error.code);if(!denialAllowed)failures++; }
    else if([result isKindOfClass:[NSArray class]])fprintf(stdout,"%s: OK count=%lu\n",[name UTF8String],(unsigned long)[result count]);
    else if([result isKindOfClass:[NSString class]])fprintf(stdout,"%s: OK text bytes=%lu\n",[name UTF8String],(unsigned long)[result lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    else fprintf(stdout,"%s: OK\n",[name UTF8String]);
    if(--pending==0)exit(failures ? 1 : 0);
}
int main(void) { @autoreleasepool {
    MCAPI *api=[MCAPI sharedAPI];
    if(api.loggedIn) { fprintf(stderr,"Refusing public probe while a saved session exists.\n");return 2; }
    if(getenv("MC_NETWORK_SEARCH_ONLY")) {
        pending=1;
        [api search:@"陈奕迅" type:1 offset:0 completion:^(id result,NSError *error) { fprintf(stdout,"search items=%lu more=%d\n",(unsigned long)[result[@"items"] count],[result[@"more"] boolValue]);done(@"search",result,error,NO); }];
        CFRunLoopRun();return 0;
    }
    pending=5;
    [api search:@"陈奕迅" type:1 offset:0 completion:^(id result,NSError *error) {
        NSArray *items=result[@"items"];NSDictionary *song=[items count] ? items[0] : nil;
        if(song) {
            pending+=4;
            [api album:song[@"albumID"] completion:^(id r,NSError *e) { if(r)fprintf(stdout,"album tracks=%lu\n",(unsigned long)[r[@"tracks"] count]);done(@"album",r,e,NO); }];
            [api artist:song[@"artistID"] completion:^(id r,NSError *e) { if(r)fprintf(stdout,"artist tracks=%lu albums=%lu\n",(unsigned long)[r[@"tracks"] count],(unsigned long)[r[@"albums"] count]);done(@"artist",r,e,NO); }];
            [api lyrics:song[@"id"] completion:^(id r,NSError *e) { done(@"lyrics",r,e,NO); }];
            [api songURL:song[@"id"] quality:@"lossless" completion:^(id r,NSError *e) { if(r)fprintf(stdout,"actual format=%s bitrate=%s\n",[r[@"format"] UTF8String],[[r[@"bitrate"] description] UTF8String]);done(@"songURL",r,e,YES); }];
        }
        fprintf(stdout,"search items=%lu more=%d\n",(unsigned long)[items count],[result[@"more"] boolValue]);done(@"search",result,error,NO);
    }];
    [api discover:^(id result,NSError *error) { done(@"discover",result,error,NO); }];
    [api playlist:@"19723756" completion:^(id result,NSError *error) { if(result)fprintf(stdout,"playlist tracks=%lu\n",(unsigned long)[result[@"tracks"] count]);done(@"playlist",result,error,NO); }];
    [api createLoginKey:^(id result,NSError *error) {
        if(result[@"key"]) { pending++;[api pollLoginKey:result[@"key"] completion:^(id r,NSError *e) { fprintf(stdout,"QR poll status=%ld\n",(long)[r[@"status"] integerValue]);done(@"QR poll",r,e,NO); }]; }
        done(@"QR key (token omitted)",result,error,NO);
    }];
    [api userPlaylists:^(id result,NSError *error) { if(!error || error.code!=301)failures++;done(@"unsigned userPlaylists requires login",result,error,YES); }];
    CFRunLoopRun();
} }
