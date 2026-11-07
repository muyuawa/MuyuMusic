#import "MCMetadata.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <stdio.h>
#import <stdint.h>
#import <math.h>
#import <sys/stat.h>

static const NSUInteger MCMaxTagBytes = 1024 * 1024;
static const NSUInteger MCMaxPictureBytes = 4 * 1024 * 1024;
static NSError *MCMetadataError(NSString *path, NSString *reason) {
    return [NSError errorWithDomain:@"MCLibraryMetadata"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : reason, NSFilePathErrorKey : path ?: @""}];
}
static uint32_t MCBE32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static uint32_t MCLE32(const uint8_t *p) {
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | p[0];
}
static BOOL MCRead(FILE *file, void *bytes, size_t count) {
    return fread(bytes, 1, count, file) == count;
}
static BOOL MCSkip(FILE *file, uint64_t count, uint64_t end) {
    off_t position = ftello(file);
    if (position < 0 || (uint64_t)position > end || count > end - (uint64_t)position)
        return NO;
    return fseeko(file, (off_t)count, SEEK_CUR) == 0;
}
static NSData *MCReadData(FILE *file, NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    return MCRead(file, data.mutableBytes, count) ? data : nil;
}
static NSString *MCSavePicture(NSData *data, NSString *directory) {
    if (!data.length || data.length > MCMaxPictureBytes)
        return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData(
        (__bridge CFDataRef)data, (__bridge CFDictionaryRef)
                                      @{(__bridge NSString *)kCGImageSourceShouldCache : @NO});
    if (!source)
        return nil;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
    double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
    CGImageRef thumbnail = NULL;
    if (width > 0 && height > 0 && width * height <= 40000000.0)
        thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, (__bridge CFDictionaryRef) @{
                (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform : @YES,
                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize : @256,
                (__bridge NSString *)kCGImageSourceShouldCache : @NO
            });
    CFRelease(source);
    if (!thumbnail)
        return nil;
    NSString *path = [directory
        stringByAppendingPathComponent:[[[NSUUID UUID] UUIDString] stringByAppendingPathExtension:@"jpg"]];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.jpeg"), 1, NULL);
    BOOL success = NO;
    if (destination) {
        CGImageDestinationAddImage(
            destination, thumbnail,
            (__bridge CFDictionaryRef)
                @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.8});
        success = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(thumbnail);
    if (!success) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        return nil;
    }
    return path;
}
static void MCComment(NSMutableDictionary *metadata, NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length, position = 0;
    if (length < 8)
        return;
    uint32_t vendor = MCLE32(bytes);
    if (vendor > length - 8)
        return;
    position = 4 + vendor;
    uint32_t count = MCLE32(bytes + position);
    position += 4;
    for (uint32_t i = 0; i < count && position + 4 <= length && i < 8192; i++) {
        uint32_t size = MCLE32(bytes + position);
        position += 4;
        if (size > length - position)
            break;
        if (size <= 16384) {
            NSString *tag = [[NSString alloc] initWithBytes:bytes + position
                                                     length:size
                                                   encoding:NSUTF8StringEncoding];
            NSRange equals = [tag rangeOfString:@"="];
            if (tag && equals.location != NSNotFound) {
                NSString *key = [[tag substringToIndex:equals.location] uppercaseString];
                NSString *field =
                    [@{@"TITLE" : @"title", @"ARTIST" : @"artist", @"ALBUM" : @"album"} objectForKey:key];
                if (field)
                    metadata[field] = [tag substringFromIndex:equals.location + 1];
            }
        }
        position += size;
    }
}
static NSData *MCFLACPicture(NSData *block) {
    const uint8_t *bytes = block.bytes;
    NSUInteger length = block.length, p = 4;
    if (length < 32)
        return nil;
    uint32_t mime = MCBE32(bytes + p);
    p += 4;
    if (mime > length - p || (mime == 3 && !memcmp(bytes + p, "-->", 3)))
        return nil;
    p += mime;
    if (length - p < 4)
        return nil;
    uint32_t description = MCBE32(bytes + p);
    p += 4;
    if (description > length - p)
        return nil;
    p += description;
    if (length - p < 20)
        return nil;
    p += 16;
    uint32_t size = MCBE32(bytes + p);
    p += 4;
    if (size > MCMaxPictureBytes || size > length - p)
        return nil;
    return [block subdataWithRange:NSMakeRange(p, size)];
}
static BOOL MCFLACMetadata(FILE *file, uint64_t fileSize, NSMutableDictionary *metadata, NSString *directory,
                           NSError **error, NSString *path) {
    uint8_t magic[4];
    if (!MCRead(file, magic, 4) || memcmp(magic, "fLaC", 4)) {
        if (error)
            *error = MCMetadataError(path, @"Invalid FLAC file header.");
        return NO;
    }
    BOOL last = NO, streamInfo = NO;
    NSUInteger blocks = 0;
    while (!last && blocks++ < 4096) {
        uint8_t header[4];
        if (!MCRead(file, header, 4))
            break;
        last = (header[0] & 128) != 0;
        unsigned type = header[0] & 127;
        uint32_t length = ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | header[3];
        off_t position = ftello(file);
        if (position < 0 || (uint64_t)position > fileSize || length > fileSize - (uint64_t)position)
            break;
        if (blocks == 1 && (type != 0 || length != 34))
            break;
        if (type == 0) {
            if (streamInfo || length != 34)
                break;
            uint8_t bytes[34];
            if (!MCRead(file, bytes, 34))
                break;
            uint64_t packed = 0;
            for (unsigned i = 10; i < 18; i++)
                packed = (packed << 8) | bytes[i];
            unsigned rate = (unsigned)(packed >> 44), channels = (unsigned)((packed >> 41) & 7) + 1,
                     depth = (unsigned)((packed >> 36) & 31) + 1;
            uint64_t samples = packed & 0xfffffffffULL;
            if (!rate || rate > 655350 || depth < 4 || depth > 32 || !channels)
                break;
            // A zero total sample count is FLAC's valid "unknown duration" value.
            metadata[@"sampleRate"] = @(rate);
            metadata[@"bitDepth"] = @(depth);
            metadata[@"duration"] = @((double)samples / rate);
            streamInfo = YES;
        } else if (type == 4 && length <= MCMaxTagBytes) {
            NSData *comments = MCReadData(file, length);
            if (!comments)
                break;
            MCComment(metadata, comments);
        } else if (type == 6 && length <= MCMaxPictureBytes) {
            NSData *picture = MCReadData(file, length);
            if (!picture)
                break;
            if (![metadata[@"artwork"] length]) {
                NSString *saved = MCSavePicture(MCFLACPicture(picture), directory);
                if (saved)
                    metadata[@"artwork"] = saved;
            }
        } else if (type == 127 || !MCSkip(file, length, fileSize))
            break;
        if (last && streamInfo) {
            uint8_t frame[4];
            if (MCRead(file, frame, 4) && frame[0] == 0xff && (frame[1] & 0xfe) == 0xf8 &&
                (frame[2] >> 4) != 0 && (frame[2] & 15) != 15 && !(frame[3] & 1) && (frame[3] >> 4) <= 10 &&
                ((frame[3] >> 1) & 7) != 3)
                return YES;
            break;
        }
    }
    if (error)
        *error = MCMetadataError(path, @"Truncated or invalid FLAC metadata or audio frame header.");
    return NO;
}
// ID3 artwork is read one bounded frame at a time; AVFoundation's artwork value is never requested.
static NSData *MCID3Picture(FILE *file, uint64_t offset, uint64_t limit) {
    if (offset > limit || limit - offset < 10 || fseeko(file, (off_t)offset, SEEK_SET))
        return nil;
    uint8_t h[10];
    if (!MCRead(file, h, 10) || memcmp(h, "ID3", 3) || h[3] < 2 || h[3] > 4 || (h[5] & 0xc0))
        return nil;
    for (int i = 6; i < 10; i++)
        if (h[i] & 128)
            return nil;
    uint64_t size = ((uint32_t)h[6] << 21) | ((uint32_t)h[7] << 14) | ((uint32_t)h[8] << 7) | h[9];
    if (size > limit - offset - 10)
        return nil;
    uint64_t end = offset + 10 + size;
    unsigned version = h[3];
    for (unsigned frames = 0; frames < 8192; frames++) {
        off_t p = ftello(file);
        unsigned headerSize = version == 2 ? 6 : 10;
        if (p < 0 || (uint64_t)p > end || end - (uint64_t)p < headerSize)
            return nil;
        uint8_t frame[10] = {0};
        if (!MCRead(file, frame, headerSize) || !frame[0])
            return nil;
        uint32_t length = version == 2 ? ((uint32_t)frame[3] << 16) | ((uint32_t)frame[4] << 8) | frame[5]
                                       : MCBE32(frame + 4);
        if (version == 4) {
            if ((frame[4] | frame[5] | frame[6] | frame[7]) & 128)
                return nil;
            length = ((uint32_t)frame[4] << 21) | ((uint32_t)frame[5] << 14) | ((uint32_t)frame[6] << 7) |
                     frame[7];
        }
        BOOL picture = version == 2 ? !memcmp(frame, "PIC", 3) : !memcmp(frame, "APIC", 4);
        if (length > end - (uint64_t)ftello(file))
            return nil;
        if (picture && length <= MCMaxPictureBytes && length > 5 && (version == 2 || !(frame[9] & 0xff))) {
            NSData *data = MCReadData(file, length);
            const uint8_t *b = data.bytes;
            NSUInteger n = data.length, q = 1;
            if (!data)
                return nil;
            if (version == 2)
                q = 4;
            else {
                while (q < n && b[q])
                    q++;
                q++;
            }
            if (q >= n)
                return nil;
            q++; // picture type
            if (b[0] == 0 || b[0] == 3) {
                while (q < n && b[q])
                    q++;
                q++;
            } else if (b[0] == 1 || b[0] == 2) {
                while (q + 1 < n && (b[q] || b[q + 1]))
                    q += 2;
                q += 2;
            } else
                return nil;
            return q < n ? [data subdataWithRange:NSMakeRange(q, n - q)] : nil;
        }
        if (!MCSkip(file, length, end))
            return nil;
    }
    return nil;
}
static NSData *MCMP4Picture(FILE *file, uint64_t start, uint64_t end, unsigned depth, NSUInteger *atoms,
                            BOOL inCover) {
    if (depth > 8)
        return nil;
    uint64_t p = start;
    while (p < end && end - p >= 8 && (*atoms)++ < 16384) {
        if (fseeko(file, (off_t)p, SEEK_SET))
            return nil;
        uint8_t h[16];
        if (!MCRead(file, h, 8))
            return nil;
        uint64_t size = MCBE32(h), header = 8;
        if (size == 1) {
            if (end - p < 16 || !MCRead(file, h + 8, 8))
                return nil;
            size = ((uint64_t)MCBE32(h + 8) << 32) | MCBE32(h + 12);
            header = 16;
        }
        if (size == 0)
            size = end - p;
        if (size < header || size > end - p)
            return nil;
        uint64_t body = p + header, finish = p + size;
        if (inCover && !memcmp(h + 4, "data", 4) && finish - body >= 8 &&
            finish - body - 8 <= MCMaxPictureBytes) {
            if (fseeko(file, (off_t)(body + 8), SEEK_SET))
                return nil;
            return MCReadData(file, (NSUInteger)(finish - body - 8));
        }
        BOOL meta = !memcmp(h + 4, "meta", 4);
        if (!memcmp(h + 4, "moov", 4) || !memcmp(h + 4, "udta", 4) || meta || !memcmp(h + 4, "ilst", 4) ||
            !memcmp(h + 4, "covr", 4)) {
            if (meta) {
                if (finish - body < 4)
                    return nil;
                body += 4;
            }
            NSData *found = MCMP4Picture(file, body, finish, depth + 1, atoms, !memcmp(h + 4, "covr", 4));
            if (found)
                return found;
        }
        p = finish;
    }
    return nil;
}
static NSData *MCNativePicture(FILE *file, uint64_t size, NSString *extension) {
    if ([extension isEqual:@"mp3"] || [extension isEqual:@"aac"])
        return MCID3Picture(file, 0, size);
    if ([extension isEqual:@"m4a"] || [extension isEqual:@"alac"] || [extension isEqual:@"mp4"]) {
        NSUInteger atoms = 0;
        return MCMP4Picture(file, 0, size, 0, &atoms, NO);
    }
    if ([extension isEqual:@"wav"] || [extension isEqual:@"wave"] || [extension isEqual:@"aif"] ||
        [extension isEqual:@"aiff"]) {
        uint8_t h[12];
        rewind(file);
        if (!MCRead(file, h, 12))
            return nil;
        BOOL little = !memcmp(h, "RIFF", 4);
        uint64_t p = 12;
        for (unsigned chunks = 0; chunks < 16384 && p <= size && size - p >= 8; chunks++) {
            if (fseeko(file, (off_t)p, SEEK_SET) || !MCRead(file, h, 8))
                return nil;
            uint32_t n = little ? MCLE32(h + 4) : MCBE32(h + 4);
            if (n > size - p - 8)
                return nil;
            if (!memcmp(h, "ID3 ", 4) || !memcmp(h, "id3 ", 4))
                return MCID3Picture(file, p + 8, p + 8 + n);
            p += 8 + (uint64_t)n + (n & 1);
        }
    }
    return nil;
}
NSDictionary *MCReadAudioMetadata(NSString *path, NSString *directory, NSError **error) {
    NSString *extension = [[path pathExtension] lowercaseString];
    NSMutableDictionary *metadata = [@{
        @"title" : [[path lastPathComponent] stringByDeletingPathExtension],
        @"artist" : @"",
        @"album" : @"",
        @"artwork" : @"",
        @"duration" : @0,
        @"format" : [extension uppercaseString]
    } mutableCopy];
    FILE *file = fopen([path fileSystemRepresentation], "rb");
    struct stat st;
    if (!file || fstat(fileno(file), &st) || st.st_size <= 0) {
        if (file)
            fclose(file);
        if (error)
            *error = MCMetadataError(path, @"Audio file cannot be read.");
        return nil;
    }
    BOOL valid = YES;
    if ([extension isEqual:@"flac"])
        valid = MCFLACMetadata(file, (uint64_t)st.st_size, metadata, directory, error, path);
    else {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path]
                                                options:@{
                                                    AVURLAssetPreferPreciseDurationAndTimingKey : @YES
                                                }];
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        double duration = CMTimeGetSeconds(asset.duration);
        if (!tracks.count || !isfinite(duration) || duration <= 0) {
            valid = NO;
            if (error)
                *error = MCMetadataError(path, @"Unsupported or corrupt audio file.");
        } else {
            metadata[@"duration"] = @(duration);
            for (AVMetadataItem *item in asset.commonMetadata) {
                NSString *key = item.commonKey;
                NSString *field = [@{
                    AVMetadataCommonKeyTitle : @"title",
                    AVMetadataCommonKeyArtist : @"artist",
                    AVMetadataCommonKeyAlbumName : @"album"
                } objectForKey:key ?: @""];
                if (field) {
                    id value = item.value;
                    if ([value isKindOfClass:[NSString class]] && [value length] && [value length] <= 16384)
                        metadata[field] = value;
                }
            }
            AVAssetTrack *audio = [tracks firstObject];
            for (id value in audio.formatDescriptions) {
                CMAudioFormatDescriptionRef description = (__bridge CMAudioFormatDescriptionRef)value;
                const AudioStreamBasicDescription *asbd =
                    CMAudioFormatDescriptionGetStreamBasicDescription(description);
                if (asbd) {
                    if (asbd->mSampleRate > 0)
                        metadata[@"sampleRate"] = @(asbd->mSampleRate);
                    if (asbd->mBitsPerChannel > 0)
                        metadata[@"bitDepth"] = @(asbd->mBitsPerChannel);
                    if (asbd->mFormatID == kAudioFormatAppleLossless)
                        metadata[@"format"] = @"ALAC";
                }
            }
            NSString *picture =
                MCSavePicture(MCNativePicture(file, (uint64_t)st.st_size, extension), directory);
            if (picture)
                metadata[@"artwork"] = picture;
        }
    }
    fclose(file);
    if (!valid) {
        if ([metadata[@"artwork"] length])
            [[NSFileManager defaultManager] removeItemAtPath:metadata[@"artwork"] error:NULL];
        return nil;
    }
    return metadata;
}
