#import "MCSourceAPI.h"
#import "MCMusicSources.h"
#import "MCHTTPClient.h"
#import "MCSourceSecurity.h"
static NSError *MCSE(NSString *s) {
    return [NSError errorWithDomain:@"MCSource" code:1 userInfo:@{NSLocalizedDescriptionKey : s}];
}
static BOOL MCSURL(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length)
        return NO;
    NSURL *u = [NSURL URLWithString:s];
    return ([u.scheme.lowercaseString isEqual:@"https"] || [u.scheme.lowercaseString isEqual:@"http"]) &&
           u.host.length && !u.user && !u.password;
}
static id MCSPath(id root, NSString *path) {
    if (![path isKindOfClass:[NSString class]] || !path.length)
        return nil;
    for (NSString *k in [path componentsSeparatedByString:@"."]) {
        if ([root isKindOfClass:[NSDictionary class]])
            root = root[k];
        else if ([root isKindOfClass:[NSArray class]] && k.length &&
                 [k rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]]
                         .location == NSNotFound) {
            NSUInteger i = (NSUInteger)[k longLongValue];
            root = i < [root count] ? root[i] : nil;
        } else
            return nil;
    }
    return root;
}
static NSString *MCSReplace(NSString *s, NSDictionary *values, BOOL url) {
    NSMutableString *result = [NSMutableString string];
    NSUInteger offset = 0;
    while (offset < s.length) {
        NSRange open = [s rangeOfString:@"{" options:0 range:NSMakeRange(offset, s.length - offset)];
        if (open.location == NSNotFound) {
            [result appendString:[s substringFromIndex:offset]];
            break;
        }
        [result appendString:[s substringWithRange:NSMakeRange(offset, open.location - offset)]];
        NSRange close = [s rangeOfString:@"}"
                                 options:0
                                   range:NSMakeRange(open.location, s.length - open.location)];
        if (close.location == NSNotFound) {
            [result appendString:[s substringFromIndex:open.location]];
            break;
        }
        NSString *key =
            [s substringWithRange:NSMakeRange(open.location + 1, close.location - open.location - 1)];
        NSString *value = values[key];
        if (value) {
            if (url) {
                NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
                NSMutableString *encoded = [NSMutableString string];
                const unsigned char *p = data.bytes;
                for (NSUInteger i = 0; i < data.length; i++) {
                    unsigned char c = p[i];
                    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                        c == '-' || c == '_' || c == '.' || c == '~')
                        [encoded appendFormat:@"%c", c];
                    else
                        [encoded appendFormat:@"%%%02X", c];
                }
                value = encoded;
            }
            [result appendString:value];
        } else
            [result appendString:[s substringWithRange:NSMakeRange(open.location,
                                                                   close.location - open.location + 1)]];
        offset = close.location + 1;
    }
    return result;
}
static id MCSBody(id value, NSDictionary *values) {
    if ([value isKindOfClass:[NSString class]])
        return MCSReplace(value, values, NO);
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id x in value)
            [a addObject:MCSBody(x, values)];
        return a;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (id k in value)
            d[k] = MCSBody(value[k], values);
        return d;
    }
    return value;
}
static NSString *MCSErrorReason(id value, NSUInteger depth) {
    if (depth > 32)
        return @"音源响应嵌套过深。";
    if ([value isKindOfClass:[NSDictionary class]]) {
        BOOL failed = NO;
        for (NSString *key in @[ @"error", @"trial", @"freeTrialInfo" ]) {
            id marker = value[key];
            if (marker && marker != [NSNull null] && ![marker isEqual:@NO] && ![marker isEqual:@""])
                failed = YES;
        }
        if ([value[@"success"] isEqual:@NO])
            failed = YES;
        id code = value[@"code"];
        if (code && [code respondsToSelector:@selector(integerValue)] && [code integerValue] != 0 &&
            [code integerValue] != 200)
            failed = YES;
        if (failed) {
            id message = value[@"message"] ?: value[@"msg"] ?: value[@"error"];
            if ([message isKindOfClass:[NSDictionary class]])
                message = message[@"message"] ?: message[@"msg"];
            NSString *reason =
                MCSourceFailureText(message, @"音源返回错误或试听数据，未提供可用的完整音频。");
            return [code respondsToSelector:@selector(integerValue)]
                       ? [NSString stringWithFormat:@"%@（音源代码 %ld）", reason, (long)[code integerValue]]
                       : reason;
        }
        for (id key in value) {
            NSString *reason = MCSErrorReason(value[key], depth + 1);
            if (reason)
                return reason;
        }
    } else if ([value isKindOfClass:[NSArray class]])
        for (id item in value) {
            NSString *reason = MCSErrorReason(item, depth + 1);
            if (reason)
                return reason;
        }
    return nil;
}
@implementation MCSourceAPI
+ (NSDictionary *)validateConfiguration:(NSDictionary *)c error:(NSError **)error {
    NSString *why = nil;
    if (![c isKindOfClass:[NSDictionary class]]) {
        if (error)
            *error = MCSE(@"API 配置必须是 JSON 对象");
        return nil;
    }
    if (!why &&
        (![c[@"name"] isKindOfClass:[NSString class]] || ![c[@"name"] length] || [c[@"name"] length] > 200))
        why = @"请输入音源名称";
    NSString *url = [c[@"url"] isKindOfClass:[NSString class]] ? c[@"url"] : @"";
    NSDictionary *dummy =
        @{@"id" : @"1", @"quality" : @"128k", @"source" : @"wy", @"title" : @"t", @"artist" : @"a"};
    NSString *expanded = MCSReplace(url, dummy, YES);
    if (!why &&
        (url.length > 16384 || !MCSURL(expanded) || [expanded rangeOfString:@"{"].location != NSNotFound))
        why = @"请求地址必须为有效 HTTP/HTTPS 地址，且不能含用户名或密码";
    NSString *method =
        [c[@"method"] isKindOfClass:[NSString class]] ? [c[@"method"] uppercaseString] : @"GET";
    if (!why && ![@[ @"GET", @"POST" ] containsObject:method])
        why = @"仅支持 GET 或 POST JSON";
    id headers = c[@"headers"] ?: @{};
    if (![headers isKindOfClass:[NSDictionary class]])
        why = @"请求头必须是字符串字典";
    else
        for (id k in headers) {
            id v = headers[k];
            if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]] || ![k length] ||
                [k rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n:"]]
                        .location != NSNotFound ||
                [v rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location != NSNotFound) {
                why = @"请求头格式无效";
                break;
            }
            if ([@[
                    @"host", @"content-length", @"transfer-encoding", @"connection", @"cookie",
                    @"proxy-authorization"
                ] containsObject:[k lowercaseString]])
                why = @"不允许该请求头";
        }
    id body = c[@"bodyTemplate"];
    if (body && [body isKindOfClass:[NSString class]])
        body = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding]
                                               options:0
                                                 error:NULL];
    if (c[@"bodyTemplate"] &&
        (![method isEqual:@"POST"] || !body || ![NSJSONSerialization isValidJSONObject:body]))
        why = @"请求体必须为 POST JSON 对象或数组";
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *k in @[ @"urlPath", @"formatPath", @"sizePath", @"bitratePath" ]) {
        id v = c[k];
        if (v && (![v isKindOfClass:[NSString class]] || [v length] > 256))
            why = @"响应字段路径无效";
        else if (v)
            out[k] = v;
    }
    if (why) {
        if (error)
            *error = MCSE(why);
        return nil;
    }
    out[@"name"] = c[@"name"];
    out[@"url"] = url;
    out[@"method"] = method;
    out[@"headers"] = headers;
    if (body)
        out[@"bodyTemplate"] = body;
    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
    if (!json || json.length > 65536) {
        if (error)
            *error = MCSE(@"API 配置超过大小限制");
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
}
+ (NSDictionary *)resourceFromData:(NSData *)data
                          response:(NSDictionary *)response
                     configuration:(NSDictionary *)c
                             error:(NSError **)error {
    NSInteger status = [response[@"status"] integerValue];
    if (status < 200 || status >= 400) {
        if (error)
            *error = MCSE([NSString stringWithFormat:@"音源请求失败（HTTP %ld）。", (long)status]);
        return nil;
    }
    NSString *url = nil;
    id json = nil;
    if (status >= 300 && status < 400) {
        NSDictionary *h = response[@"headers"];
        for (NSString *k in h)
            if ([k.lowercaseString isEqual:@"location"])
                url = h[k];
        if (!url)
            url = response[@"location"];
        if ([url isKindOfClass:[NSString class]] && url.length &&
            [response[@"requestURL"] isKindOfClass:[NSString class]] && MCSURL(response[@"requestURL"])) {
            NSURL *base = [NSURL URLWithString:response[@"requestURL"]];
            NSURL *resolved = [NSURL URLWithString:url relativeToURL:base];
            url = [resolved absoluteURL].absoluteString;
        }
    } else if (status >= 200 && status < 300 && data.length && data.length <= 2 * 1024 * 1024) {
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (MCSURL(text))
            url = text;
        else {
            json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            NSString *reason = MCSErrorReason(json, 0);
            if (reason) {
                if (error)
                    *error = MCSE(reason);
                return nil;
            }
            if ([c[@"urlPath"] length])
                url = MCSPath(json, c[@"urlPath"]);
            else
                for (NSString *p in @[ @"url", @"data.url", @"data.0.url" ]) {
                    url = MCSPath(json, p);
                    if (url)
                        break;
                }
        }
    }
    if (!url || !MCSURL(url) || !MCSourceURLAllowed([NSURL URLWithString:url])) {
        if (error)
            *error = MCSE(
                MCSourceURLFailure([url isKindOfClass:[NSString class]] ? [NSURL URLWithString:url] : nil));
        return nil;
    }
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithObject:url forKey:@"url"];
    NSDictionary *paths = @{@"format" : @"formatPath", @"size" : @"sizePath", @"bitrate" : @"bitratePath"};
    for (NSString *key in paths) {
        id v = MCSPath(json, c[paths[key]]);
        if ([key isEqual:@"format"]) {
            if ([v isKindOfClass:[NSString class]] &&
                [@[ @"mp3", @"flac", @"m4a", @"aac", @"wav", @"ogg" ] containsObject:[v lowercaseString]])
                r[key] = [v lowercaseString];
        } else if ([v respondsToSelector:@selector(longLongValue)] && [v longLongValue] > 0)
            r[key] = @([v longLongValue]);
    }
    return r;
}
+ (MCSourceTask *)resolveConfiguration:(NSDictionary *)configuration
                                 track:(NSDictionary *)track
                               quality:(NSString *)quality
                            completion:(void (^)(NSDictionary *, NSError *))completion {
    MCSourceTask *task = [[MCSourceTask alloc] initWithCancellation:nil];
    NSError *err = nil;
    NSDictionary *c = [self validateConfiguration:configuration error:&err];
    if (!c) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!task.cancelled)
                completion(nil, err);
        });
        return task;
    }
    NSDictionary *values = @{
        @"id" : [track[@"id"] description] ?: @"",
        @"quality" : [quality isEqual:@"lossless"] ? @"flac"
                                                   : ([quality isEqual:@"exhigh"] ? @"320k" : @"128k"),
        @"source" : @"wy",
        @"title" : [track[@"title"] isKindOfClass:[NSString class]] ? track[@"title"] : @"",
        @"artist" : [track[@"artist"] isKindOfClass:[NSString class]] ? track[@"artist"] : @""
    };
    NSURL *url = [NSURL URLWithString:MCSReplace(c[@"url"], values, YES)];
    NSURL *configuredURL = [NSURL URLWithString:MCSReplace(c[@"url"], @{
                                      @"id" : @"1",
                                      @"quality" : @"128k",
                                      @"source" : @"wy",
                                      @"title" : @"t",
                                      @"artist" : @"a"
                                  },
                                                           YES)];
    NSString *configuredHost = configuredURL.host;
    if (!MCSourceURLAllowed(url) || ![url.host.lowercaseString isEqual:configuredHost.lowercaseString]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!task.cancelled)
                completion(nil, MCSE(MCSourceURLFailure(url)));
        });
        return task;
    }
    NSMutableDictionary *headers = [c[@"headers"] mutableCopy];
    NSData *body = nil;
    if (c[@"bodyTemplate"]) {
        body = [NSJSONSerialization dataWithJSONObject:MCSBody(c[@"bodyTemplate"], values)
                                               options:0
                                                 error:NULL];
        headers[@"Content-Type"] = @"application/json";
    }
    MCRequest *request = [[MCHTTPClient sharedClient]
        sourceRequestURL:url
                  method:c[@"method"]
                    body:body
                 headers:headers
                 timeout:40
              completion:^(NSData *data, NSDictionary *response, NSError *e) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                      if (task.cancelled)
                          return;
                      NSError *safe = e ? MCSE(MCSourceFailureText(e.localizedDescription,
                                                                   @"音源请求失败，请检查配置或网络"))
                                        : nil;
                      NSMutableDictionary *context =
                          [response mutableCopy] ?: [NSMutableDictionary dictionary];
                      context[@"requestURL"] = url.absoluteString;
                      NSDictionary *r = safe ? nil
                                             : [self resourceFromData:data
                                                             response:context
                                                        configuration:c
                                                                error:&safe];
                      completion(r, safe);
                      task.cancellation = nil;
                  });
              }];
    task.cancellation = ^{
        [request cancel];
    };
    return task;
}
@end
