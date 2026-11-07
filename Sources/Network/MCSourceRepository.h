#import <Foundation/Foundation.h>
@class MCMusicSources, MCSourceTask;
extern NSString *const MCSourceRepositoryDidChangeNotification;

/* Main-thread service. All imports and updates are serial; cancelling only stops
   unfinished work. Completed updates remain committed. No background scheduler. */
@interface MCSourceRepository : NSObject
+ (instancetype)sharedRepository;
- (instancetype)initWithDirectory:(NSString *)directory
                          sources:(MCMusicSources *)sources
                            clock:(NSTimeInterval (^)(void))clock;
@property (nonatomic, readonly, copy) NSArray *catalog;
@property (nonatomic) BOOL autoSyncEnabled;
/* GitHub or one of the download accelerators listed by the upstream README. */
@property (nonatomic, copy) NSString *downloadRoute;
+ (NSArray *)downloadRoutes;
@property (nonatomic, readonly) BOOL busy;
@property (nonatomic, readonly, copy) NSString *statusText;
@property (nonatomic, readonly, copy) NSDictionary *errors;
@property (nonatomic, readonly) NSTimeInterval lastSuccessfulCheck;
- (NSDictionary *)entryForPath:(NSString *)path;
- (NSString *)statusForItem:(NSDictionary *)item;
- (void)refreshCatalog;
- (void)importCatalogItem:(NSDictionary *)item;
- (void)synchronize;
- (void)cancel;
- (void)applicationDidBecomeActive;
+ (NSArray *)catalogFromTree:(id)tree error:(NSError **)error;
@end
