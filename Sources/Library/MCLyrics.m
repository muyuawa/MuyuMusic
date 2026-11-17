#import "MCLyrics.h"
#import <math.h>
#import <dispatch/dispatch.h>

NSString *const MCLyricsOptionsDidChangeNotification = @"MCLyricsOptionsDidChange";
static void MCLyricsDefaults(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSUserDefaults standardUserDefaults] registerDefaults:
            @{@"lyrics.translation":@YES, @"lyrics.romanization":@NO}];
    });
}
BOOL MCLyricsShowTranslation(void) { MCLyricsDefaults(); return [[NSUserDefaults standardUserDefaults] boolForKey:@"lyrics.translation"]; }
BOOL MCLyricsUseRomanization(void) { MCLyricsDefaults(); return [[NSUserDefaults standardUserDefaults] boolForKey:@"lyrics.romanization"]; }
static void MCSetLyricOption(NSString *key, BOOL value) {
    MCLyricsDefaults();
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:key];
    [[NSNotificationCenter defaultCenter] postNotificationName:MCLyricsOptionsDidChangeNotification object:nil];
}
void MCSetLyricsShowTranslation(BOOL value) { MCSetLyricOption(@"lyrics.translation", value); }
void MCSetLyricsUseRomanization(BOOL value) { MCSetLyricOption(@"lyrics.romanization", value); }

static NSString *MCVariantAtTime(NSArray *lines, NSUInteger *cursor, double time) {
    if (!lines.count) return nil;
    while (*cursor + 1 < lines.count && [lines[*cursor + 1][@"time"] doubleValue] <= time) ++*cursor;
    NSUInteger best = *cursor;
    double delta = fabs([lines[best][@"time"] doubleValue] - time);
    if (best + 1 < lines.count) {
        double next = fabs([lines[best + 1][@"time"] doubleValue] - time);
        if (next < delta) { best++; delta = next; }
    }
    return delta <= .12 ? lines[best][@"text"] : nil;
}

@implementation MCLyrics
+ (NSArray *)parseOriginal:(NSString *)original translation:(NSString *)translation romanization:(NSString *)romanization {
    NSArray *variants = @[[self parse:translation], [self parse:romanization]];
    NSArray *keys = @[@"translation", @"romanization"];
    NSUInteger cursors[2] = {0, 0};
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *line in [self parse:original]) {
        NSMutableDictionary *merged = [line mutableCopy];
        for (NSUInteger i=0;i<2;i++) {
            NSString *words = MCVariantAtTime(variants[i], &cursors[i], [line[@"time"] doubleValue]);
            if (words.length) merged[keys[i]] = words;
        }
        [result addObject:merged];
    }
    return result;
}
+ (NSString *)displayTextForLine:(NSDictionary *)line romanization:(BOOL)romanization {
    if (romanization && [line[@"romanization"] length]) return line[@"romanization"];
    return line[@"text"] ?: @"";
}
+ (NSArray *)parse:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || !text.length)
        return @[];
    NSError *error = nil;
    NSRegularExpression *offsetPattern =
        [NSRegularExpression regularExpressionWithPattern:@"\\[offset:([+-]?[0-9]+)\\]"
                                                  options:NSRegularExpressionCaseInsensitive
                                                    error:&error];
    double offset = 0;
    NSArray *offsets = [offsetPattern matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    if (offsets.count)
        offset = [[text substringWithRange:[[offsets lastObject] rangeAtIndex:1]] doubleValue] / 1000.0;
    NSRegularExpression *stamp = [NSRegularExpression
        regularExpressionWithPattern:@"\\[([0-9]{1,5}):([0-5][0-9])(?:[.:]([0-9]{1,3}))?\\]"
                             options:0
                               error:&error];
    NSMutableArray *result = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSArray *matches = [stamp matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!matches.count)
            continue;
        NSUInteger start = NSMaxRange([[matches lastObject] range]);
        NSString *words = [[line substringFromIndex:start]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        for (NSTextCheckingResult *match in matches) {
            double time = [[line substringWithRange:[match rangeAtIndex:1]] doubleValue] * 60 +
                          [[line substringWithRange:[match rangeAtIndex:2]] doubleValue];
            NSRange fraction = [match rangeAtIndex:3];
            if (fraction.location != NSNotFound)
                time += [[line substringWithRange:fraction] doubleValue] / pow(10.0, fraction.length);
            [result addObject:@{@"time" : @(time + offset), @"text" : words, @"sequence" : @(result.count)}];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [a[@"time"] compare:b[@"time"]];
        return order == NSOrderedSame ? [a[@"sequence"] compare:b[@"sequence"]] : order;
    }];
    NSMutableArray *lines = [NSMutableArray arrayWithCapacity:result.count];
    for (NSDictionary *line in result)
        [lines addObject:@{@"time" : line[@"time"], @"text" : line[@"text"]}];
    return lines;
}
+ (NSInteger)indexAtTime:(NSTimeInterval)time lines:(NSArray *)lines {
    if (!isfinite(time) || !lines.count)
        return -1;
    NSUInteger low = 0, high = lines.count;
    while (low < high) {
        NSUInteger middle = low + (high - low) / 2;
        if ([lines[middle][@"time"] doubleValue] <= time)
            low = middle + 1;
        else
            high = middle;
    }
    return low ? (NSInteger)low - 1 : -1;
}
@end
