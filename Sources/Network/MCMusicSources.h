#import <Foundation/Foundation.h>
extern NSString *const MCMusicSourcesDidChangeNotification;
/* Fixed repository identity; no arbitrary URLs or filenames from saved metadata. */
NSDictionary *MCValidatedSourceSubscription(id value);
NSString *MCSourceGitBlobSHA(NSData *data);
/* Main-queue completions. Cancellation is thread safe, idempotent; assigning
   cancellation after cancellation immediately invokes the newly assigned block. */
@interface MCSourceTask : NSObject
- (instancetype)initWithCancellation:(void (^)(void))block;
@property (nonatomic, copy) void (^cancellation)(void);
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end
@interface MCMusicSources : NSObject
+ (instancetype)sharedSources;
- (instancetype)initWithDirectory:(NSString *)directory;
@property (nonatomic, readonly, copy) NSArray *entries;
@property (nonatomic, readonly, copy) NSString *selectedIdentifier;
@property (nonatomic, readonly, copy) NSDictionary *selectedEntry;
- (NSString *)consumeRecoveryNotice;
- (BOOL)selectIdentifier:(NSString *)identifier error:(NSError **)error;
- (BOOL)removeIdentifier:(NSString *)identifier error:(NSError **)error;
- (NSDictionary *)saveAPIConfiguration:(NSDictionary *)configuration
                            identifier:(NSString *)identifier
                                 error:(NSError **)error;
- (MCSourceTask *)importScript:(NSString *)script
                        origin:(NSString *)origin
                    completion:(void (^)(NSDictionary *, NSError *))completion;
- (MCSourceTask *)importScriptURL:(NSURL *)url completion:(void (^)(NSDictionary *, NSError *))completion;
/* Replacement checks the target's original revision before committing. Same-content
   imports can bind an existing local entry. Completion runs on the main queue. */
- (MCSourceTask *)importScript:(NSString *)script
                  subscription:(NSDictionary *)subscription
           replacingIdentifier:(NSString *)identifier
                    completion:(void (^)(NSDictionary *, NSError *))completion;
- (MCSourceTask *)importScriptData:(NSData *)data
                      subscription:(NSDictionary *)subscription
               replacingIdentifier:(NSString *)identifier
                        completion:(void (^)(NSDictionary *, NSError *))completion;
- (MCSourceTask *)resolveTrack:(NSDictionary *)track
                       quality:(NSString *)quality
                    completion:(void (^)(NSDictionary *, NSError *))completion;
@end
