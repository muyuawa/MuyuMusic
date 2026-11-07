#import <Foundation/Foundation.h>
@interface MCRequest : NSObject
- (void)cancel;
@end
@interface MCHTTPClient : NSObject
+ (instancetype)sharedClient;
- (MCRequest *)requestURL:(NSURL *)url
                   method:(NSString *)method
                     body:(NSData *)body
                  headers:(NSDictionary *)headers
               completion:(void (^)(NSData *, NSDictionary *, NSError *))completion;
/* Explicit user-source control request. HTTP is allowed only when the user
   disables the default HTTPS-only source setting. 2 MiB decoded body,
   bounded timeout, no redirects/cookie jar/account credential injection.
   User-supplied Authorization/Cookie headers are allowed only on this path. */
- (MCRequest *)sourceRequestURL:(NSURL *)url
                         method:(NSString *)method
                           body:(NSData *)body
                        headers:(NSDictionary *)headers
                        timeout:(NSTimeInterval)timeout
                     completion:(void (^)(NSData *, NSDictionary *, NSError *))completion;
/* All three stream callbacks run on a bounded worker. No automatic redirects.
   HTTP 3xx returns its response and finishes; caller may explicitly request a
   verified HTTPS Location. Cookies/authorization are never sent on streams. */
- (MCRequest *)streamURL:(NSURL *)url
                 headers:(NSDictionary *)headers
                response:(void (^)(NSDictionary *))response
                    data:(BOOL (^)(const void *, size_t))data
              completion:(void (^)(NSError *))completion;
/* Selected third-party audio only. Same streaming/credential rules, with the
   user-configured source protocol policy. Ordinary streams remain HTTPS-only. */
- (MCRequest *)sourceStreamURL:(NSURL *)url
                       headers:(NSDictionary *)headers
                      response:(void (^)(NSDictionary *))response
                          data:(BOOL (^)(const void *, size_t))data
                    completion:(void (^)(NSError *))completion;
@end
