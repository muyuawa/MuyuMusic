#import "MCLyrics.h"
#import <math.h>

@implementation MCLyrics
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
