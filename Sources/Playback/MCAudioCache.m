#import "MCAudioCache.h"
#import <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static const unsigned long long MCMaximumCacheBytes = 1024ULL * 1024 * 1024;
static NSString *const MCCachePreference = @"audioCache.maximumBytes";

static NSString *MCDigest(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || !text.length)
        return nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length > UINT32_MAX)
        return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (unsigned i = 0; i < sizeof digest; i++)
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return [NSString stringWithUTF8String:hex];
}
static NSString *MCFileKey(NSString *key) {
    return [key isKindOfClass:[NSString class]] && key.length <= 1024 ? MCDigest(key) : nil;
}
static NSError *MCCacheError(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code ?: EIO userInfo:nil];
}
/* Only the fallback copy uses memory, in fixed 64 KiB blocks. The source is a
   completed spool, retained by the caller until its main-queue completion. */
static int MCCopyAudio(NSString *source, NSString *target) {
    int input = open(source.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (input < 0)
        return errno;
    int output = open(target.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
    int error = output < 0 ? errno : 0;
    unsigned char buffer[64 * 1024];
    while (!error) {
        ssize_t count;
        do {
            count = read(input, buffer, sizeof buffer);
        } while (count < 0 && errno == EINTR);
        if (count <= 0) {
            if (count < 0)
                error = errno;
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(output, buffer + offset, (size_t)(count - offset));
            if (written < 0 && errno == EINTR)
                continue;
            if (written <= 0) {
                error = written < 0 ? errno : EIO;
                break;
            }
            offset += written;
        }
    }
    if (output >= 0 && close(output) && !error)
        error = errno;
    close(input);
    return error;
}

@interface MCCacheEntry : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *sourceIdentifier;
@property (nonatomic) unsigned long long bytes;
@property (nonatomic) NSTimeInterval accessed;
@property (nonatomic) NSUInteger pins;
@property (nonatomic) BOOL invalid;
@end
@implementation MCCacheEntry
@end

@interface MCAudioCache () {
    NSString *_directory;
    dispatch_queue_t _worker;
    NSMutableDictionary *_entries;
    unsigned long long _maximumBytes;
    NSUInteger _generation;
    BOOL _persistsPreference;
    NSError *_diskError;
}
- (void)releaseEntry:(MCCacheEntry *)entry;
@end
@interface MCAudioCacheLease ()
@property (nonatomic, readwrite, copy) NSString *path;
@property (nonatomic, strong) MCAudioCache *owner;
@property (nonatomic, strong) MCCacheEntry *entry;
@end
@implementation MCAudioCacheLease
- (void)dealloc {
    [_owner releaseEntry:_entry];
}
@end

@implementation MCAudioCache
+ (MCAudioCache *)sharedCache {
    static MCAudioCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        id preference = [defaults objectForKey:MCCachePreference];
        unsigned long long limit = [preference isKindOfClass:[NSNumber class]]
                                       ? [preference unsignedLongLongValue]
                                       : 256ULL * 1024 * 1024;
        NSString *base =
            [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        cache = [[self alloc] initWithDirectory:[base stringByAppendingPathComponent:@"MuyuMusic/Audio"]
                                   maximumBytes:limit];
        cache->_persistsPreference = YES;
    });
    return cache;
}
- (id)initWithDirectory:(NSString *)directory maximumBytes:(unsigned long long)bytes {
    if ((self = [super init])) {
        _directory = [directory copy];
        _maximumBytes = MIN(bytes, MCMaximumCacheBytes);
        _entries = [NSMutableDictionary dictionary];
        _worker = dispatch_queue_create("music.audio.cache", DISPATCH_QUEUE_SERIAL);
        dispatch_async(_worker, ^{
            @autoreleasepool {
                [self loadEntries];
                [self trim];
            }
        });
    }
    return self;
}
- (unsigned long long)maximumBytes {
    @synchronized(self) {
        return _maximumBytes;
    }
}
- (void)setMaximumBytes:(unsigned long long)bytes {
    bytes = MIN(bytes, MCMaximumCacheBytes);
    @synchronized(self) {
        _maximumBytes = bytes;
        if (!bytes)
            _generation++;
    }
    dispatch_async(_worker, ^{
        @autoreleasepool {
            if (self->_persistsPreference)
                [[NSUserDefaults standardUserDefaults] setObject:@(bytes) forKey:MCCachePreference];
            [self trim];
        }
    });
}
- (NSUInteger)generation {
    @synchronized(self) {
        return _generation;
    }
}
+ (NSString *)keyForTrackID:(NSString *)identifier
                   resource:(NSDictionary *)resource
                    account:(NSString *)account {
    if (![identifier isKindOfClass:[NSString class]] || !identifier.length ||
        ![account isKindOfClass:[NSString class]] || !account.length ||
        ![resource isKindOfClass:[NSDictionary class]])
        return nil;
    NSString *rawURL = resource[@"url"], *format = resource[@"format"];
    if (![rawURL isKindOfClass:[NSString class]] || ![format isKindOfClass:[NSString class]] ||
        !format.length)
        return nil;
    NSURL *url = [NSURL URLWithString:rawURL];
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length || !url.path.length ||
        url.user || url.password)
        return nil;
    id size = resource[@"size"], bitrate = resource[@"bitrate"];
    if (![size isKindOfClass:[NSNumber class]] || [size doubleValue] <= 0 ||
        ![bitrate isKindOfClass:[NSNumber class]] || [bitrate doubleValue] < 0)
        return nil;
    /* JSON arrays keep field boundaries unambiguous. CDN host and expiring URL
       query credentials do not identify the actual encoded music resource. */
    NSArray *fields = @[ account, identifier, url.path, format.lowercaseString, size, bitrate ];
    if ([resource[@"customSource"] boolValue]) {
        NSString *source = resource[@"sourceIdentifier"], *revision = resource[@"sourceRevision"];
        if (![source isKindOfClass:[NSString class]] || !source.length ||
            ![revision isKindOfClass:[NSString class]] || !revision.length)
            return nil;
        fields = @[
            @"custom-source-v1", source, revision, url.host.lowercaseString, url.port ?: @443, account,
            identifier, url.path, format.lowercaseString, size, bitrate
        ];
    }
    NSData *identity = [NSJSONSerialization dataWithJSONObject:fields options:0 error:NULL];
    return identity ? MCDigest([[NSString alloc] initWithData:identity encoding:NSUTF8StringEncoding]) : nil;
}
- (BOOL)prepareDirectory {
    NSError *error = nil;
    BOOL ready = [[NSFileManager defaultManager] createDirectoryAtPath:_directory
                                           withIntermediateDirectories:YES
                                                            attributes:nil
                                                                 error:&error];
    if (!ready)
        _diskError = error;
    return ready;
}
- (void)loadEntries {
    if (![self prepareDirectory])
        return;
    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:_directory error:&error];
    if (error)
        _diskError = error;
    NSCharacterSet *nonHex =
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    for (NSString *name in files) {
        NSString *path = [_directory stringByAppendingPathComponent:name];
        if ([name hasPrefix:@".store-"]) {
            unlink(path.fileSystemRepresentation);
            continue;
        }
        if (![name.pathExtension isEqualToString:@"audio"])
            continue;
        NSString *key = name.stringByDeletingPathExtension;
        if (key.length != 64 || [key rangeOfCharacterFromSet:nonHex].location != NSNotFound)
            continue;
        struct stat info;
        NSString *marker = [path stringByAppendingString:@".invalid"];
        if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0) {
            unlink(path.fileSystemRepresentation);
            unlink(marker.fileSystemRepresentation);
            continue;
        }
        MCCacheEntry *entry = [MCCacheEntry new];
        entry.path = path;
        NSString *sourcePath = [path stringByAppendingString:@".source"];
        int sourceFD = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
        if (sourceFD >= 0) {
            char bytes[129];
            ssize_t count = read(sourceFD, bytes, sizeof bytes);
            close(sourceFD);
            if (count > 0 && count <= 128)
                entry.sourceIdentifier = [[NSString alloc] initWithBytes:bytes
                                                                  length:(NSUInteger)count
                                                                encoding:NSUTF8StringEncoding];
        }
        entry.bytes = (unsigned long long)info.st_size;
        entry.accessed = info.st_mtimespec.tv_sec + info.st_mtimespec.tv_nsec / 1e9;
        _entries[key] = entry;
        if (!access(marker.fileSystemRepresentation, F_OK))
            [self invalidateEntry:entry];
    }
}
- (unsigned long long)usedBytes {
    unsigned long long used = 0;
    for (MCCacheEntry *entry in _entries.allValues)
        used += entry.bytes;
    return used;
}
- (BOOL)removeEntry:(MCCacheEntry *)entry {
    if (entry.pins)
        return NO;
    if (unlink(entry.path.fileSystemRepresentation) && errno != ENOENT) {
        _diskError = MCCacheError(errno);
        return NO;
    }
    unlink([[entry.path stringByAppendingString:@".invalid"] fileSystemRepresentation]);
    unlink([[entry.path stringByAppendingString:@".source"] fileSystemRepresentation]);
    [_entries removeObjectForKey:entry.path.lastPathComponent.stringByDeletingPathExtension];
    return YES;
}
- (void)invalidateEntry:(MCCacheEntry *)entry {
    entry.invalid = YES;
    if ([self removeEntry:entry])
        return;
    /* The marker prevents cleared or corrupt pinned data being reused after
       a crash; its audio pathname stays intact until the last reader closes. */
    int fd = open([[entry.path stringByAppendingString:@".invalid"] fileSystemRepresentation],
                  O_WRONLY | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0)
        _diskError = MCCacheError(errno);
    else
        close(fd);
}
- (void)trim {
    unsigned long long limit = self.maximumBytes;
    NSArray *oldest =
        [_entries.allValues sortedArrayUsingComparator:^NSComparisonResult(MCCacheEntry *a, MCCacheEntry *b) {
            if (a.accessed != b.accessed)
                return a.accessed < b.accessed ? NSOrderedAscending : NSOrderedDescending;
            return [a.path compare:b.path];
        }];
    for (MCCacheEntry *entry in oldest)
        if (entry.invalid && !entry.pins)
            [self removeEntry:entry];
    unsigned long long used = [self usedBytes];
    for (MCCacheEntry *entry in oldest) {
        if (used <= limit)
            break;
        if (!entry.pins && _entries[entry.path.lastPathComponent.stringByDeletingPathExtension] &&
            [self removeEntry:entry])
            used -= entry.bytes;
    }
    if (used > limit)
        for (MCCacheEntry *entry in _entries.allValues)
            if (entry.pins)
                [self invalidateEntry:entry];
}
- (NSDictionary *)stats {
    unsigned long long pending = 0;
    for (MCCacheEntry *entry in _entries.allValues)
        if (entry.invalid)
            pending += entry.bytes;
    NSMutableDictionary *stats = [@{
        @"usedBytes" : @([self usedBytes]),
        @"limitBytes" : @(self.maximumBytes),
        @"pendingBytes" : @(pending)
    } mutableCopy];
    if (_diskError)
        stats[@"error"] = _diskError;
    return stats;
}
- (void)leaseForKey:(NSString *)key completion:(void (^)(MCAudioCacheLease *))completion {
    NSString *fileKey = MCFileKey(key);
    dispatch_async(_worker, ^{
        @autoreleasepool {
            MCCacheEntry *entry = fileKey ? self->_entries[fileKey] : nil;
            MCAudioCacheLease *lease = nil;
            if (entry && !entry.invalid && self.maximumBytes) {
                struct stat info;
                if (lstat(entry.path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
                    info.st_size <= 0 || (unsigned long long)info.st_size != entry.bytes) {
                    [self invalidateEntry:entry];
                } else {
                    entry.pins++;
                    entry.accessed = [NSDate date].timeIntervalSince1970;
                    utimes(entry.path.fileSystemRepresentation, NULL);
                    lease = [MCAudioCacheLease new];
                    lease.path = entry.path;
                    lease.owner = self;
                    lease.entry = entry;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion)
                    completion(lease);
            });
        }
    });
}
- (void)releaseEntry:(MCCacheEntry *)entry {
    dispatch_async(_worker, ^{
        @autoreleasepool {
            if (entry.pins)
                entry.pins--;
            if (entry.invalid)
                [self removeEntry:entry];
            [self trim];
        }
    });
}
- (void)storeFile:(NSString *)path key:(NSString *)key completion:(void (^)(void))completion {
    [self storeFile:path key:key generation:self.generation completion:completion];
}
- (void)storeFile:(NSString *)path
              key:(NSString *)key
       generation:(NSUInteger)generation
       completion:(void (^)(void))completion {
    [self storeFile:path key:key sourceIdentifier:nil generation:generation completion:completion];
}
- (void)storeFile:(NSString *)path
                 key:(NSString *)key
    sourceIdentifier:(NSString *)sourceIdentifier
          generation:(NSUInteger)generation
          completion:(void (^)(void))completion {
    NSString *source = [path copy], *fileKey = MCFileKey(key);
    NSString *owner = [sourceIdentifier isKindOfClass:[NSString class]] && sourceIdentifier.length <= 128
                          ? [sourceIdentifier copy]
                          : nil;
    dispatch_async(_worker, ^{
        @autoreleasepool {
            [self storeSource:source fileKey:fileKey sourceIdentifier:owner generation:generation];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion)
                    completion();
            });
        }
    });
}
- (void)storeSource:(NSString *)source
             fileKey:(NSString *)key
    sourceIdentifier:(NSString *)owner
          generation:(NSUInteger)generation {
    unsigned long long limit = self.maximumBytes;
    if (!key || !source.length || !limit || generation != self.generation || _entries[key])
        return;
    struct stat info;
    if (lstat(source.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 ||
        (unsigned long long)info.st_size > limit || ![self prepareDirectory])
        return;
    /* Reserve room before copying so the cap includes the staging file. Pins
       and deferred clear bytes count against this budget as well. */
    NSArray *oldest = [self->_entries.allValues
        sortedArrayUsingComparator:^NSComparisonResult(MCCacheEntry *a, MCCacheEntry *b) {
            return a.accessed < b.accessed ? NSOrderedAscending : NSOrderedDescending;
        }];
    unsigned long long used = [self usedBytes], bytes = (unsigned long long)info.st_size;
    for (MCCacheEntry *entry in oldest) {
        if (used <= limit - bytes)
            break;
        if ([self removeEntry:entry])
            used -= entry.bytes;
    }
    if (used > limit - bytes || generation != self.generation)
        return;
    NSString *temporary = [_directory
        stringByAppendingPathComponent:[@".store-" stringByAppendingString:[[NSUUID UUID] UUIDString]]];
    int error = 0;
    if (link(source.fileSystemRepresentation, temporary.fileSystemRepresentation))
        error = MCCopyAudio(source, temporary);
    struct stat stored;
    if (!error && (lstat(temporary.fileSystemRepresentation, &stored) || !S_ISREG(stored.st_mode) ||
                   stored.st_size != info.st_size))
        error = EIO;
    NSString *target = [_directory stringByAppendingPathComponent:[key stringByAppendingString:@".audio"]];
    @synchronized(self) {
        if (!error && generation == _generation && bytes <= _maximumBytes &&
            [self usedBytes] <= _maximumBytes - bytes) {
            if (rename(temporary.fileSystemRepresentation, target.fileSystemRepresentation))
                error = errno;
            else {
                MCCacheEntry *entry = [MCCacheEntry new];
                entry.path = target;
                entry.sourceIdentifier = owner;
                NSString *sourcePath = [target stringByAppendingString:@".source"];
                if (owner.length) {
                    if (![[owner dataUsingEncoding:NSUTF8StringEncoding] writeToFile:sourcePath
                                                                          atomically:YES]) {
                        unlink(target.fileSystemRepresentation);
                        error = EIO;
                    }
                } else
                    unlink(sourcePath.fileSystemRepresentation);
                entry.bytes = bytes;
                entry.accessed = [NSDate date].timeIntervalSince1970;
                utimes(target.fileSystemRepresentation, NULL);
                if (!error) {
                    _entries[key] = entry;
                    _diskError = nil;
                }
            }
        }
    }
    unlink(temporary.fileSystemRepresentation);
    if (error)
        _diskError = MCCacheError(error);
    [self trim];
}
- (void)snapshot:(void (^)(NSDictionary *))completion {
    dispatch_async(_worker, ^{
        @autoreleasepool {
            NSDictionary *stats = [self stats];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion)
                    completion(stats);
            });
        }
    });
}
- (void)clear:(void (^)(NSDictionary *, NSError *))completion {
    @synchronized(self) {
        _generation++;
    }
    dispatch_async(_worker, ^{
        @autoreleasepool {
            self->_diskError = nil;
            [self prepareDirectory];
            for (MCCacheEntry *entry in self->_entries.allValues)
                [self invalidateEntry:entry];
            NSDictionary *stats = [self stats];
            NSError *error = self->_diskError;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion)
                    completion(stats, error);
            });
        }
    });
}
- (void)invalidateSourceIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:[NSString class]] || !identifier.length)
        return;
    NSString *owner = [identifier copy];
    dispatch_async(_worker, ^{
        @autoreleasepool {
            for (MCCacheEntry *entry in self->_entries.allValues)
                if ([entry.sourceIdentifier isEqualToString:owner])
                    [self invalidateEntry:entry];
        }
    });
}
- (void)invalidateKey:(NSString *)key {
    NSString *fileKey = MCFileKey(key);
    dispatch_async(_worker, ^{
        @autoreleasepool {
            MCCacheEntry *entry = fileKey ? self->_entries[fileKey] : nil;
            if (entry)
                [self invalidateEntry:entry];
        }
    });
}
@end
