#import "MCHTTPClient.h"
#import "MCEAPI.h"
#import "MCSourceSecurity.h"
#import <curl/curl.h>
#import <TargetConditionals.h>
#import <dispatch/dispatch.h>
#include <math.h>

static NSUInteger const MCMaxJSONBytes = 8 * 1024 * 1024;
static NSError *MCHTTPError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"MCHTTPErrorDomain"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : text}];
}
@interface MCRequest ()
- (BOOL)isCancelled;
@end
@implementation MCRequest {
    BOOL _cancelled;
}
- (void)cancel {
    @synchronized(self) {
        _cancelled = YES;
    }
}
- (BOOL)isCancelled {
    @synchronized(self) {
        return _cancelled;
    }
}
@end

@interface MCTransfer : NSObject {
  @public
    MCRequest *request;
    NSMutableDictionary *headers;
    NSMutableData *buffer;
    NSUInteger headerBytes, maximumBytes;
    NSInteger status;
    BOOL streaming, responded, tooLarge;
    void (^responseBlock)(NSDictionary *);
    BOOL (^dataBlock)(const void *, size_t);
}
- (NSDictionary *)response;
@end
@implementation MCTransfer
- (NSDictionary *)response {
    NSMutableDictionary *h = [headers mutableCopy];
    h[@"status"] = @(status);
    h[@"headers"] = [headers copy];
    return [h copy];
}
@end
static size_t MCReceiveHeader(char *bytes, size_t size, size_t count, void *context) {
    MCTransfer *t = (__bridge MCTransfer *)context;
    size_t length = size * count;
    if ([t->request isCancelled])
        return 0;
    if (length > 65536 || t->headerBytes > 65536 - length) {
        t->tooLarge = YES;
        return 0;
    }
    t->headerBytes += length;
    NSString *line = [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
    if ([line hasPrefix:@"HTTP/"]) {
        NSArray *parts = [line componentsSeparatedByString:@" "];
        t->status = [parts count] > 1 ? [parts[1] integerValue] : 0;
        [t->headers removeAllObjects];
    } else if ([line isEqual:@"\r\n"] || [line isEqual:@"\n"]) {
        if (t->streaming && t->status >= 200 && !t->responded) {
            t->responded = YES;
            if (t->responseBlock)
                t->responseBlock([t response]);
        }
    } else {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *key = [[line substringToIndex:colon.location] lowercaseString];
            NSString *value = [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([key isEqual:@"set-cookie"]) {
                NSMutableArray *cookies = [t->headers[key] mutableCopy] ?: [NSMutableArray array];
                [cookies addObject:value];
                t->headers[key] = cookies;
            } else
                t->headers[key] = value;
        }
    }
    return length;
}
static size_t MCReceiveBytes(char *bytes, size_t size, size_t count, void *context) {
    MCTransfer *t = (__bridge MCTransfer *)context;
    size_t length = size * count;
    if ([t->request isCancelled])
        return 0;
    if (t->streaming) {
        /* Redirect/error HTML must never enter the audio decoder. */
        if (t->status != 200 && t->status != 206)
            return length;
        for (size_t offset = 0; offset < length;) {
            size_t block = MIN((size_t)32768, length - offset);
            if ([t->request isCancelled] || (t->dataBlock && !t->dataBlock(bytes + offset, block))) {
                [t->request cancel];
                return 0;
            }
            offset += block;
        }
    } else {
        if (length > t->maximumBytes || [t->buffer length] > t -> maximumBytes - length) {
            t->tooLarge = YES;
            return 0;
        }
        [t->buffer appendBytes:bytes length:length];
    }
    return length;
}
static int MCProgress(void *context, curl_off_t downTotal, curl_off_t downNow, curl_off_t upTotal,
                      curl_off_t upNow) {
    (void)downTotal;
    (void)downNow;
    (void)upTotal;
    (void)upNow;
    return [((__bridge MCTransfer *)context)->request isCancelled] ? 1 : 0;
}
@interface MCHTTPClient ()
@property (nonatomic, strong) NSOperationQueue *workers;
@end
@implementation MCHTTPClient
+ (instancetype)sharedClient {
    static MCHTTPClient *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        client = [[self alloc] init];
    });
    return client;
}
- (instancetype)init {
    if ((self = [super init])) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            curl_global_init(CURL_GLOBAL_DEFAULT);
        });
        _workers = [[NSOperationQueue alloc] init];
        [_workers setMaxConcurrentOperationCount:3];
        [_workers setName:@"Muyu HTTPS workers"];
    }
    return self;
}
- (NSString *)CAPath {
    NSString *path = [[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"];
#if TARGET_OS_OSX
    if (!path)
        path = [[[NSFileManager defaultManager] currentDirectoryPath]
            stringByAppendingPathComponent:@"Resources/cacert.pem"];
#endif
    return path;
}
- (MCRequest *)performURL:(NSURL *)url
                   method:(NSString *)method
                     body:(NSData *)body
                  headers:(NSDictionary *)input
                streaming:(BOOL)streaming
            customControl:(BOOL)customControl
                  timeout:(NSTimeInterval)timeout
                 response:(void (^)(NSDictionary *))response
                     data:(BOOL (^)(const void *, size_t))data
               completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    url = [url copy];
    method = [method copy];
    body = [body copy];
    input = [input copy];
    BOOL allowHTTP = customControl && !MCSourceHTTPSOnly();
    MCRequest *r = [[MCRequest alloc] init];
    [_workers addOperationWithBlock:^{
        @autoreleasepool {
            MCTransfer *t = [[MCTransfer alloc] init];
            t->request = r;
            t->headers = [NSMutableDictionary dictionary];
            t->streaming = streaming;
            t->maximumBytes = customControl ? 2 * 1024 * 1024 : MCMaxJSONBytes;
            t->buffer = streaming ? nil : [NSMutableData data];
            t->responseBlock = [response copy];
            t->dataBlock = [data copy];
            NSError *error = nil;
            CURL *curl = NULL;
            struct curl_slist *list = NULL;
            NSString *ca = [self CAPath];
            if ([r isCancelled])
                error = [NSError errorWithDomain:NSURLErrorDomain
                                            code:NSURLErrorCancelled
                                        userInfo:@{NSLocalizedDescriptionKey : @"请求已取消"}];
            else if (customControl &&
                     (body.length > 2 * 1024 * 1024 ||
                      ![@[ @"GET", @"POST", @"PUT", @"PATCH", @"DELETE", @"HEAD", @"OPTIONS" ]
                          containsObject:method.uppercaseString]))
                error = MCHTTPError(-5, @"自定义请求无效或超过大小限制");
            else if (!([url.scheme.lowercaseString isEqual:@"https"] ||
                       (allowHTTP && [url.scheme.lowercaseString isEqual:@"http"])) ||
                     ![[url host] length] || [url user] || [url password])
                error = MCHTTPError(-1, customControl ? MCSourceURLFailure(url)
                                                      : @"只允许使用通过验证的 HTTPS 连接");
            else if ([url.scheme.lowercaseString isEqual:@"https"] &&
                     ![[NSFileManager defaultManager] fileExistsAtPath:ca])
                error = MCHTTPError(-2, @"缺少 TLS 证书库 cacert.pem");
            else if (!(curl = curl_easy_init()))
                error = MCHTTPError(-3, @"无法初始化网络连接");
            if (curl) {
                curl_easy_setopt(curl, CURLOPT_URL, [[url absoluteString] UTF8String]);
                curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, [method UTF8String]);
                curl_easy_setopt(curl, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
                curl_easy_setopt(curl, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
                curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
                curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
                curl_easy_setopt(curl, CURLOPT_CAINFO, [ca fileSystemRepresentation]);
                curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, allowHTTP ? "https,http" : "https");
                curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, allowHTTP ? "https,http" : "https");
                curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
                curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 0L);
                curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
                curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
                NSTimeInterval boundedTimeout =
                    isfinite(timeout) && timeout > 0 ? MIN(60.0, MAX(0.1, timeout)) : 40.0;
                curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, streaming ? 0L : (long)(boundedTimeout * 1000));
                curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 32L);
                curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 30L);
                curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
                curl_easy_setopt(curl, CURLOPT_BUFFERSIZE, 16384L);
                curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
                curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, MCProgress);
                curl_easy_setopt(curl, CURLOPT_XFERINFODATA, (__bridge void *)t);
                curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, MCReceiveBytes);
                curl_easy_setopt(curl, CURLOPT_WRITEDATA, (__bridge void *)t);
                curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, MCReceiveHeader);
                curl_easy_setopt(curl, CURLOPT_HEADERDATA, (__bridge void *)t);
                curl_easy_setopt(curl, CURLOPT_USERAGENT, "MuyuCloudMusic/1.0");
                if (body) {
                    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, [body bytes]);
                    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)[body length]);
                }
                NSUInteger sentHeaderBytes = 0;
                for (id key in input) {
                    id value = input[key];
                    if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]])
                        continue;
                    NSString *lower = [key lowercaseString];
                    BOOL credential = [lower isEqual:@"cookie"] || [lower isEqual:@"authorization"] ||
                                      [lower isEqual:@"proxy-authorization"];
                    if ([lower isEqual:@"proxy-authorization"] ||
                        (credential && (streaming || (!customControl && ![MCEAPI isAPIHost:[url host]]))))
                        continue;
                    if ([lower isEqual:@"host"] || [lower isEqual:@"content-length"] ||
                        [key rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location !=
                            NSNotFound ||
                        [value rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location !=
                            NSNotFound)
                        continue;
                    if ([key length] > 256 || [value length] > 8192 ||
                        sentHeaderBytes > 65536 - [key length] - [value length])
                        continue;
                    sentHeaderBytes += [key length] + [value length];
                    list = curl_slist_append(list,
                                             [[NSString stringWithFormat:@"%@: %@", key, value] UTF8String]);
                }
                list = curl_slist_append(list, "Expect:");
                curl_easy_setopt(curl, CURLOPT_HTTPHEADER, list);
                CURLcode code = curl_easy_perform(curl);
                long status = 0;
                curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
                t->status = status;
                if ([r isCancelled])
                    error = [NSError errorWithDomain:NSURLErrorDomain
                                                code:NSURLErrorCancelled
                                            userInfo:@{NSLocalizedDescriptionKey : @"请求已取消"}];
                else if (t->tooLarge)
                    error = MCHTTPError(-4, @"网络响应超过安全大小限制");
                else if (code != CURLE_OK) {
                    NSString *reason;
                    switch (code) {
                    case CURLE_COULDNT_RESOLVE_HOST:
                        reason = @"无法解析服务器域名，请检查网络或切换音源。";
                        break;
                    case CURLE_COULDNT_CONNECT:
                        reason = @"无法连接服务器，请检查网络或稍后重试。";
                        break;
                    case CURLE_OPERATION_TIMEDOUT:
                        reason = @"服务器响应超时，请稍后重试。";
                        break;
                    case CURLE_PEER_FAILED_VERIFICATION:
                        reason = @"TLS 证书验证失败，请检查设备日期或联系音源服务商。";
                        break;
                    case CURLE_SSL_CONNECT_ERROR:
                        reason = @"TLS 握手失败，服务器可能不支持此设备的连接。";
                        break;
                    default:
                        reason = [NSString stringWithFormat:@"网络连接失败：%s", curl_easy_strerror(code)];
                        break;
                    }
                    error = MCHTTPError(code,
                                        [NSString stringWithFormat:@"%@（网络错误 %d）", reason, (int)code]);
                } else if (status >= 400 || status < 200)
                    error = MCHTTPError(
                        status, [NSString stringWithFormat:customControl ? @"自定义源请求失败（HTTP %ld）"
                                                                         : @"网易云网络请求失败（HTTP %ld）",
                                                           status]);
                curl_easy_cleanup(curl);
                curl_slist_free_all(list);
            }
            NSDictionary *result = [t response];
            NSData *bytes = [t->buffer copy];
            if (completion) {
                if (streaming)
                    completion(bytes, result, error);
                else
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(bytes, result, error);
                    });
            }
        }
    }];
    return r;
}
- (MCRequest *)requestURL:(NSURL *)url
                   method:(NSString *)method
                     body:(NSData *)body
                  headers:(NSDictionary *)headers
               completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    return [self performURL:url
                     method:method ?: @"GET"
                       body:body
                    headers:headers
                  streaming:NO
              customControl:NO
                    timeout:40
                   response:nil
                       data:nil
                 completion:completion];
}
- (MCRequest *)sourceRequestURL:(NSURL *)url
                         method:(NSString *)method
                           body:(NSData *)body
                        headers:(NSDictionary *)headers
                        timeout:(NSTimeInterval)timeout
                     completion:(void (^)(NSData *, NSDictionary *, NSError *))completion {
    return [self performURL:url
                     method:method ?: @"GET"
                       body:body
                    headers:headers
                  streaming:NO
              customControl:YES
                    timeout:timeout
                   response:nil
                       data:nil
                 completion:completion];
}
- (MCRequest *)streamURL:(NSURL *)url
                 headers:(NSDictionary *)headers
                response:(void (^)(NSDictionary *))response
                    data:(BOOL (^)(const void *, size_t))data
              completion:(void (^)(NSError *))completion {
    return [self performURL:url
                     method:@"GET"
                       body:nil
                    headers:headers
                  streaming:YES
              customControl:NO
                    timeout:0
                   response:response
                       data:data
                 completion:^(NSData *bytes, NSDictionary *result, NSError *error) {
                     (void)bytes;
                     (void)result;
                     if (completion)
                         completion(error);
                 }];
}
- (MCRequest *)sourceStreamURL:(NSURL *)url
                       headers:(NSDictionary *)headers
                      response:(void (^)(NSDictionary *))response
                          data:(BOOL (^)(const void *, size_t))data
                    completion:(void (^)(NSError *))completion {
    return [self performURL:url
                     method:@"GET"
                       body:nil
                    headers:headers
                  streaming:YES
              customControl:YES
                    timeout:0
                   response:response
                       data:data
                 completion:^(NSData *bytes, NSDictionary *result, NSError *error) {
                     (void)bytes;
                     (void)result;
                     if (completion)
                         completion(error);
                 }];
}
@end
