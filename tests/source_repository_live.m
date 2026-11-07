#import <Foundation/Foundation.h>
#import "MCSourceRepository.h"
#import "MCMusicSources.h"
static BOOL Wait(MCSourceRepository *repository) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:60];
    while (repository.busy && end.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    if (repository.busy) {
        [repository cancel];
        return NO;
    }
    return YES;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        MCMusicSources *sources =
            [[MCMusicSources alloc] initWithDirectory:[folder stringByAppendingPathComponent:@"sources"]];
        __block NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        MCSourceRepository *repository = [[MCSourceRepository alloc]
            initWithDirectory:[folder stringByAppendingPathComponent:@"repository"]
                      sources:sources
                        clock:^{
                            return now;
                        }];
        if (argc > 1)
            repository.downloadRoute = [NSString stringWithUTF8String:argv[1]];
        printf("live download route: %s\n", repository.downloadRoute.UTF8String);
        [repository refreshCatalog];
        BOOL success = Wait(repository) && repository.catalog.count > 0;
        printf("live directory: %lu items; %s\n", (unsigned long)repository.catalog.count,
               repository.statusText.UTF8String);
        fflush(stdout);
        NSUInteger compatible = 0;
        for (NSDictionary *item in repository.catalog) {
            now += 5;
            [repository importCatalogItem:item];
            if (!Wait(repository)) {
                success = NO;
                break;
            }
            NSDictionary *entry = [repository entryForPath:item[@"path"]];
            if (entry && [entry[@"selectable"] boolValue])
                compatible++;
            printf("%s: %s; %s\n", [item[@"path"] UTF8String],
                   entry ? "imported/blob verified" : "not imported",
                   [repository statusForItem:item].UTF8String);
            fflush(stdout);
        }
        if (![sources.selectedIdentifier isEqual:@"netease"])
            success = NO;
        printf("live result: %lu/%lu declared wy/musicUrl; playback NOT tested; default=%s\n",
               (unsigned long)compatible, (unsigned long)repository.catalog.count,
               sources.selectedIdentifier.UTF8String);
        [repository cancel];
        repository = nil;
        sources = nil;
        [[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];
        return success ? 0 : 1;
    }
}
