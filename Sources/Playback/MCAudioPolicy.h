#import <Foundation/Foundation.h>
/* Custom policy is opt-in on a resource returned by a user-selected source. */
BOOL MCIsAllowedAudioURL(NSURL *url, BOOL customSource);

BOOL MCSourceSnapshotMatches(NSDictionary *snapshot, NSDictionary *selection);
