#import <Foundation/Foundation.h>

/* Pure protocol/parsing helpers, separated so host tests exercise production code. */
@interface MCEAPI : NSObject
+ (NSString *)encryptedParamsForPath:(NSString *)path JSON:(NSString *)JSON error:(NSError **)error;
+ (NSDictionary *)decodeResponse:(NSData *)data error:(NSError **)error;
+ (NSString *)identifier:(id)value;
+ (NSDictionary *)track:(NSDictionary *)song;
+ (NSDictionary *)catalogItem:(NSDictionary *)item;
+ (NSDictionary *)playableURL:(NSDictionary *)entry error:(NSError **)error;
+ (BOOL)isAPIHost:(NSString *)host;
@end
FOUNDATION_EXPORT NSString *const MCAPIErrorDomain;
