#import "MCArtwork.h"
#import "MCHTTPClient.h"
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>
@interface MCArtwork ()
@property (nonatomic, strong) NSCache *memory;
@property (nonatomic) dispatch_queue_t disk;
@property (nonatomic, copy) NSString *directory;
@end
@implementation MCArtwork
+ (instancetype)sharedCache {
    static MCArtwork *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = [MCArtwork new];
    });
    return a;
}
- (id)init {
    if ((self = [super init])) {
        _memory = [NSCache new];
        _memory.totalCostLimit = 4 * 1024 * 1024;
        _memory.countLimit = 80;
        _disk = dispatch_queue_create("com.muyu.artwork", DISPATCH_QUEUE_SERIAL);
        _directory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES)[0]
            stringByAppendingPathComponent:@"Artwork"];
        dispatch_async(_disk, ^{
            [[NSFileManager defaultManager] createDirectoryAtPath:self.directory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
        });
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(warning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}
- (void)warning {
    [self.memory removeAllObjects];
}
- (NSString *)key:(NSString *)s {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *k = [NSMutableString string];
    for (unsigned i = 0; i < sizeof(digest); i++)
        [k appendFormat:@"%02x", digest[i]];
    return k;
}
- (UIImage *)decode:(NSData *)data {
    if (!data.length || data.length > 4 * 1024 * 1024)
        return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source)
        return nil;
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef) @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize : @256,
        (id)kCGImageSourceCreateThumbnailWithTransform : @YES
    });
    UIImage *u = img ? [UIImage imageWithCGImage:img] : nil;
    if (img)
        CGImageRelease(img);
    CFRelease(source);
    return u;
}
- (void)display:(UIImage *)image location:(NSString *)location view:(UIImageView *)view {
    if (image && [objc_getAssociatedObject(view, @selector(load:into:)) isEqual:location]) {
        view.image = image;
        [view.superview setNeedsLayout];
        void (^completion)(UIImage *) = objc_getAssociatedObject(view, @selector(load:into:completion:));
        if (completion) completion(image);
    }
}
- (void)load:(NSString *)location into:(UIImageView *)view {
    [self load:location into:view completion:nil];
}
- (void)load:(NSString *)location into:(UIImageView *)view completion:(void (^)(UIImage *))completion {
    MCRequest *previous = objc_getAssociatedObject(view, @selector(warning));
    [previous cancel];
    objc_setAssociatedObject(view, @selector(warning), nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.image = [UIImage imageNamed:@"AppPlaceholder"];
    objc_setAssociatedObject(view, @selector(load:into:completion:), completion, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(view, @selector(load:into:), location, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (completion) completion(nil);
    if (!location.length)
        return;
    UIImage *cached = [self.memory objectForKey:location];
    if (cached) {
        view.image = cached;
        if (completion) completion(cached);
        return;
    }
    __weak UIImageView *weakView = view;
    dispatch_async(self.disk, ^{
        if (!weakView || ![objc_getAssociatedObject(weakView, @selector(load:into:)) isEqual:location])
            return;
        NSString *cache = [self.directory stringByAppendingPathComponent:[self key:location]];
        BOOL remote = [location hasPrefix:@"https://"];
        NSData *data = [NSData dataWithContentsOfFile:remote ? cache : location
                                              options:NSDataReadingMappedIfSafe
                                                error:NULL];
        UIImage *image = [self decode:data];
        if (image) {
            [self.memory setObject:image forKey:location cost:256 * 256 * 4];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self display:image location:location view:weakView];
            });
            return;
        }
        if (!remote)
            return;
        NSString *url = [location stringByAppendingString:[location rangeOfString:@"?"].location == NSNotFound
                                                              ? @"?param=256y256"
                                                              : @"&param=256y256"];
        MCRequest *request = [[MCHTTPClient sharedClient]
            requestURL:[NSURL URLWithString:url]
                method:@"GET"
                  body:nil
               headers:nil
            completion:^(NSData *bytes, NSDictionary *response, NSError *error) {
                if (error || [response[@"status"] integerValue] != 200)
                    return;
                dispatch_async(self.disk, ^{
                    UIImage *decoded = [self decode:bytes];
                    if (!decoded)
                        return;
                    NSData *small = UIImageJPEGRepresentation(decoded, .82);
                    [small writeToFile:cache atomically:YES];
                    [self.memory setObject:decoded forKey:location cost:256 * 256 * 4];
                    [self trim];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self display:decoded location:location view:weakView];
                    });
                });
            }];
        objc_setAssociatedObject(weakView, @selector(warning), request, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}
- (void)trim {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:self.directory error:NULL];
    unsigned long long total = 0;
    NSMutableArray *entries = [NSMutableArray array];
    for (NSString *file in files) {
        NSString *p = [self.directory stringByAppendingPathComponent:file];
        NSDictionary *a = [fm attributesOfItemAtPath:p error:NULL];
        total += [a fileSize];
        [entries addObject:@{
            @"path" : p,
            @"size" : a[NSFileSize] ?: @0,
            @"date" : a[NSFileModificationDate] ?: [NSDate distantPast]
        }];
    }
    if (total <= 32 * 1024 * 1024)
        return;
    [entries sortUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:YES] ]];
    for (NSDictionary *e in entries) {
        [fm removeItemAtPath:e[@"path"] error:NULL];
        total -= [e[@"size"] unsignedLongLongValue];
        if (total <= 24 * 1024 * 1024)
            break;
    }
}
- (void)clearDisk:(void (^)(void))completion {
    [self.memory removeAllObjects];
    dispatch_async(self.disk, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *file in [fm contentsOfDirectoryAtPath:self.directory error:NULL])
            [fm removeItemAtPath:[self.directory stringByAppendingPathComponent:file] error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
                completion();
        });
    });
}
@end
