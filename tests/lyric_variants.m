#import <Foundation/Foundation.h>
#import "MCLyrics.h"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        NSArray *lines = [MCLyrics parseOriginal:@"[00:01.00]君の声\n[00:03.00]空へ\n[00:05.00]原文だけ"
            translation:@"[00:01.02]你的声音\n[00:03.00]飞向天空\n[00:08.00]不应错配"
            romanization:@"[00:01.00]kimi no koe\n[00:03.03]sora e"];
        assert(lines.count == 3);
        assert([lines[0][@"translation"] isEqual:@"你的声音"]);
        assert([lines[1][@"romanization"] isEqual:@"sora e"]);
        assert([MCLyrics displayTextForLine:lines[0] romanization:NO] &&
               [[MCLyrics displayTextForLine:lines[0] romanization:NO] isEqual:@"君の声"]);
        assert([[MCLyrics displayTextForLine:lines[0] romanization:YES] isEqual:@"kimi no koe"]);
        assert([[MCLyrics displayTextForLine:lines[2] romanization:YES] isEqual:@"原文だけ"]);
        assert(!lines[2][@"translation"] && !lines[2][@"romanization"]);
        assert([MCLyrics indexAtTime:3.1 lines:lines] == 1);
        NSArray *local = [MCLyrics parseOriginal:@"[00:02]本地歌词" translation:nil romanization:nil];
        assert([[MCLyrics displayTextForLine:local[0] romanization:YES] isEqual:@"本地歌词"]);
        puts("Lyric variants: timestamp alignment, original/romanization selection and missing-data fallback passed");
    }
}
