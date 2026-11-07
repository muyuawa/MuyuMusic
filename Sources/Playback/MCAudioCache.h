#import <Foundation/Foundation.h>

@interface MCAudioCacheLease : NSObject
@property (nonatomic, readonly, copy) NSString *path;
@end

@interface MCAudioCache : NSObject
+ (MCAudioCache *)sharedCache;
- (id)initWithDirectory:(NSString *)directory maximumBytes:(unsigned long long)bytes;
@property (nonatomic) unsigned long long maximumBytes;
/* Capture when a download begins. Clearing/disabling invalidates older stores. */
@property (nonatomic, readonly) NSUInteger generation;
+ (NSString *)keyForTrackID:(NSString *)identifier
                   resource:(NSDictionary *)resource
                    account:(NSString *)account;
- (void)leaseForKey:(NSString *)key completion:(void (^)(MCAudioCacheLease *lease))completion;
- (void)storeFile:(NSString *)path key:(NSString *)key completion:(void (^)(void))completion;
- (void)storeFile:(NSString *)path
              key:(NSString *)key
       generation:(NSUInteger)generation
       completion:(void (^)(void))completion;
/* Source owner is private metadata, used only to purge deleted custom sources. */
- (void)storeFile:(NSString *)path
                 key:(NSString *)key
    sourceIdentifier:(NSString *)sourceIdentifier
          generation:(NSUInteger)generation
          completion:(void (^)(void))completion;
- (void)invalidateSourceIdentifier:(NSString *)identifier;
- (void)snapshot:(void (^)(NSDictionary *stats))completion;
- (void)clear:(void (^)(NSDictionary *stats, NSError *error))completion;
- (void)invalidateKey:(NSString *)key;
@end
