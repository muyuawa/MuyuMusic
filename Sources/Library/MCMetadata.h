#import <Foundation/Foundation.h>
// Runs on the library worker. Never reads entire audio files into memory.
NSDictionary *MCReadAudioMetadata(NSString *path, NSString *artworkDirectory, NSError **error);
