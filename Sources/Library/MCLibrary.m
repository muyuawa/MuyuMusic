#import "MCLibrary.h"
#import "MCMetadata.h"
#import <sqlite3.h>
#import <dispatch/dispatch.h>
#import <CoreFoundation/CoreFoundation.h>
#import <math.h>

NSString *const MCLibraryDidChangeNotification = @"MCLibraryDidChangeNotification";
static NSError *MCLibraryError(NSInteger code, NSString *message, NSString *path) {
    NSMutableDictionary *info =
        [@{NSLocalizedDescriptionKey : message ?: @"Library operation failed."} mutableCopy];
    if (path)
        info[NSFilePathErrorKey] = path;
    return [NSError errorWithDomain:@"MCLibrary" code:code userInfo:info];
}
static NSString *MCCacheNamespace(NSString *path) {
    // This only separates cache directories; it is not used as a track identity.
    uint64_t hash = 1469598103934665603ULL;
    NSData *bytes = [path dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        hash ^= p[i];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%016llx", (unsigned long long)hash];
}
@interface MCLibrary () {
    sqlite3 *_database;
    dispatch_queue_t _queue;
    NSString *_databasePath;
    NSString *_documentsPath;
    NSString *_artworkDirectory;
    NSMutableArray *_errors;
    NSError *_openError;
}
@end
@implementation MCLibrary
+ (MCLibrary *)sharedLibrary {
    static MCLibrary *library;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *documents =
            [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *support =
            [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
        library = [[self alloc]
            initWithDatabasePath:[support stringByAppendingPathComponent:@"MuyuMusic/music.sqlite"]
                   documentsPath:documents];
    });
    return library;
}
- (id)initWithDatabasePath:(NSString *)path documentsPath:(NSString *)documents {
    if ((self = [super init])) {
        _databasePath = [[path stringByStandardizingPath] copy];
        _documentsPath = [[documents stringByStandardizingPath] copy];
        _queue = dispatch_queue_create("com.muyu.music.library", DISPATCH_QUEUE_SERIAL);
        _errors = [NSMutableArray array];
        NSString *caches =
            [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        _artworkDirectory = [[caches
            stringByAppendingPathComponent:[@"MuyuMusic/Covers"
                                               stringByAppendingPathComponent:MCCacheNamespace(_databasePath
                                                                                                   ?: @"")]]
            copy];
        dispatch_async(_queue, ^{
            [self openDatabase];
        });
    }
    return self;
}
- (void)dealloc {
    if (_database)
        sqlite3_close(_database);
}
- (void)addSQLiteError {
    NSString *message = _database ? [NSString stringWithUTF8String:sqlite3_errmsg(_database)]
                                  : @"Library database is unavailable.";
    [_errors addObject:MCLibraryError(_database ? sqlite3_errcode(_database) : SQLITE_CANTOPEN, message,
                                      _databasePath)];
}
- (BOOL)execute:(NSString *)sql arguments:(NSArray *)arguments {
    if (!_database) {
        [_errors addObject:_openError
                               ?: MCLibraryError(SQLITE_CANTOPEN, @"Library database is unavailable.",
                                                 _databasePath)];
        return NO;
    }
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
        [self addSQLiteError];
        return NO;
    }
    BOOL bound = YES;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        id value = arguments[i];
        int status;
        if ([value isKindOfClass:[NSData class]])
            status = sqlite3_bind_blob(statement, (int)i + 1, [value bytes], (int)[value length],
                                       SQLITE_TRANSIENT);
        else if ([value isKindOfClass:[NSNumber class]])
            status = sqlite3_bind_double(statement, (int)i + 1, [value doubleValue]);
        else if ([value isKindOfClass:[NSString class]])
            status = sqlite3_bind_text(statement, (int)i + 1, [value UTF8String], -1, SQLITE_TRANSIENT);
        else
            status = sqlite3_bind_null(statement, (int)i + 1);
        if (status != SQLITE_OK) {
            bound = NO;
            [self addSQLiteError];
            break;
        }
    }
    int status = bound ? sqlite3_step(statement) : SQLITE_ERROR;
    BOOL success = bound && (status == SQLITE_DONE || status == SQLITE_ROW);
    if (bound && !success)
        [self addSQLiteError];
    sqlite3_finalize(statement);
    return success;
}
- (NSArray *)query:(NSString *)sql arguments:(NSArray *)arguments {
    if (!_database) {
        [_errors addObject:_openError
                               ?: MCLibraryError(SQLITE_CANTOPEN, @"Library database is unavailable.",
                                                 _databasePath)];
        return @[];
    }
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
        [self addSQLiteError];
        return @[];
    }
    for (NSUInteger i = 0; i < arguments.count; i++) {
        id value = arguments[i];
        int status = [value isKindOfClass:[NSNumber class]]
                         ? sqlite3_bind_double(statement, (int)i + 1, [value doubleValue])
                         : sqlite3_bind_text(statement, (int)i + 1, [value UTF8String], -1, SQLITE_TRANSIENT);
        if (status != SQLITE_OK) {
            [self addSQLiteError];
            sqlite3_finalize(statement);
            return @[];
        }
    }
    NSMutableArray *rows = [NSMutableArray array];
    int status;
    while ((status = sqlite3_step(statement)) == SQLITE_ROW) {
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        for (int i = 0; i < sqlite3_column_count(statement); i++) {
            NSString *key = [NSString stringWithUTF8String:sqlite3_column_name(statement, i)];
            id value = nil;
            switch (sqlite3_column_type(statement, i)) {
            case SQLITE_TEXT: {
                const char *text = (const char *)sqlite3_column_text(statement, i);
                value = text ? [NSString stringWithUTF8String:text] : @"";
                break;
            }
            case SQLITE_INTEGER:
                value = @(sqlite3_column_int64(statement, i));
                break;
            case SQLITE_FLOAT:
                value = @(sqlite3_column_double(statement, i));
                break;
            case SQLITE_BLOB:
                value = [NSData dataWithBytes:sqlite3_column_blob(statement, i)
                                       length:(NSUInteger)sqlite3_column_bytes(statement, i)];
                break;
            default:
                break;
            }
            if (value)
                row[key] = value;
        }
        [rows addObject:row];
    }
    if (status != SQLITE_DONE)
        [self addSQLiteError];
    sqlite3_finalize(statement);
    return rows;
}
- (void)openDatabase {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (!_databasePath.length || !_documentsPath.length) {
        _openError = MCLibraryError(SQLITE_CANTOPEN, @"Library paths are missing.", _databasePath);
        return;
    }
    if (![fm createDirectoryAtPath:[_databasePath stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&error]) {
        _openError = error;
        return;
    }
    if (![fm createDirectoryAtPath:_artworkDirectory
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&error])
        [_errors addObject:error];
    if (sqlite3_open_v2([_databasePath fileSystemRepresentation], &_database,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
                        NULL) != SQLITE_OK) {
        [self addSQLiteError];
        _openError = [_errors lastObject];
        if (_database) {
            sqlite3_close(_database);
            _database = NULL;
        }
        [_errors removeAllObjects];
        return;
    }
    sqlite3_busy_timeout(_database, 2000);
    const char *schema = "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
                         "CREATE TABLE IF NOT EXISTS tracks(id TEXT PRIMARY KEY NOT NULL,path TEXT "
                         "UNIQUE,json BLOB NOT NULL,mtime REAL,size INTEGER);"
                         "CREATE TABLE IF NOT EXISTS favorites(track_id TEXT PRIMARY KEY NOT NULL REFERENCES "
                         "tracks(id) ON DELETE CASCADE);"
                         "CREATE TABLE IF NOT EXISTS recent(track_id TEXT PRIMARY KEY NOT NULL REFERENCES "
                         "tracks(id) ON DELETE CASCADE,played INTEGER NOT NULL);"
                         "CREATE TABLE IF NOT EXISTS playlists(id TEXT PRIMARY KEY NOT NULL,title TEXT NOT "
                         "NULL,created INTEGER NOT NULL);"
                         "CREATE TABLE IF NOT EXISTS playlist_tracks(playlist_id TEXT NOT NULL REFERENCES "
                         "playlists(id) ON DELETE CASCADE,track_id TEXT NOT NULL REFERENCES tracks(id) ON "
                         "DELETE CASCADE,position INTEGER NOT NULL,PRIMARY KEY(playlist_id,track_id));"
                         "CREATE INDEX IF NOT EXISTS playlist_order ON "
                         "playlist_tracks(playlist_id,position); PRAGMA user_version=1;";
    if (sqlite3_exec(_database, schema, NULL, NULL, NULL) != SQLITE_OK) {
        [self addSQLiteError];
        _openError = [_errors lastObject];
        sqlite3_close(_database);
        _database = NULL;
        [_errors removeAllObjects];
    }
}
- (NSArray *)takeErrors {
    NSArray *result = [_errors copy];
    [_errors removeAllObjects];
    return result;
}
- (void)notifyChange:(BOOL)changed {
    NSArray *errors = [self takeErrors];
    if (!changed && !errors.count)
        return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:MCLibraryDidChangeNotification
                          object:self
                        userInfo:errors.count ? @{@"errors" : errors} : nil];
    });
}
- (NSArray *)decodeRows:(NSArray *)rows {
    NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSDictionary *row in rows) {
        NSError *error = nil;
        NSData *data = row[@"json"];
        id track = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        if ([track isKindOfClass:[NSDictionary class]])
            [tracks addObject:track];
        else
            [_errors
                addObject:error
                              ?: MCLibraryError(SQLITE_CORRUPT, @"A saved track contains invalid metadata.",
                                                _databasePath)];
    }
    return tracks;
}
- (NSDictionary *)normalizedTrack:(NSDictionary *)input {
    if (![input isKindOfClass:[NSDictionary class]])
        return nil;
    id identifier = input[@"id"];
    if ([identifier isKindOfClass:[NSNumber class]])
        identifier = [identifier stringValue];
    if (![identifier isKindOfClass:[NSString class]] || ![identifier length])
        return nil;
    NSMutableDictionary *track = [NSMutableDictionary dictionaryWithObject:identifier forKey:@"id"];
    for (NSString *key in
         @[ @"title", @"artist", @"album", @"artwork", @"path", @"format", @"artistID", @"albumID" ]) {
        id value = input[key];
        if ([value isKindOfClass:[NSString class]])
            track[key] = value;
        else if ([@[ @"title", @"artist", @"album", @"artwork" ] containsObject:key])
            track[key] = @"";
    }
    if (![track[@"title"] length])
        track[@"title"] = @"Untitled";
    for (NSString *key in @[ @"duration", @"sampleRate", @"bitDepth" ]) {
        id value = input[key];
        if ([value isKindOfClass:[NSNumber class]] && isfinite([value doubleValue]) &&
            [value doubleValue] >= 0)
            track[key] = value;
    }
    if (!track[@"duration"])
        track[@"duration"] = @0;
    return track;
}
- (NSString *)storeExternalTrack:(NSDictionary *)input {
    NSDictionary *track = [self normalizedTrack:input];
    if (!track) {
        [_errors addObject:MCLibraryError(2, @"This track has no valid identifier.", nil)];
        return nil;
    }
    NSString *identifier = track[@"id"];
    NSArray *existing = [self query:@"SELECT id FROM tracks WHERE id=?" arguments:@[ identifier ]];
    if ([identifier hasPrefix:@"local:"]) {
        if (!existing.count) {
            [_errors
                addObject:MCLibraryError(2, @"The local track is no longer in the library.", track[@"path"])];
            return nil;
        }
        return identifier;
    }
    // Online entries have no local path; only scan is allowed to create local tracks.
    NSMutableDictionary *online = [track mutableCopy];
    [online removeObjectForKey:@"path"];
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:online options:0 error:&error];
    if (!json) {
        [_errors addObject:error];
        return nil;
    }
    BOOL ok = [self execute:@"INSERT OR IGNORE INTO tracks(id,json) VALUES(?,?)"
                  arguments:@[ identifier, json ]];
    if (ok)
        ok = [self execute:@"UPDATE tracks SET json=? WHERE id=? AND path IS NULL"
                 arguments:@[ json, identifier ]];
    return ok ? identifier : nil;
}
- (void)tracksMatching:(NSString *)query completion:(void (^)(NSArray *))completion {
    NSString *needle = [query isKindOfClass:[NSString class]] ? [query copy] : @"";
    dispatch_async(_queue, ^{
        NSArray *all = [self decodeRows:[self query:@"SELECT json FROM tracks WHERE path IS NOT NULL"
                                            arguments:@[]]];
        NSMutableArray *matches = [NSMutableArray array];
        for (NSDictionary *track in all) {
            BOOL match = !needle.length;
            for (NSString *key in @[ @"title", @"artist", @"album" ])
                if ([track[key] rangeOfString:needle
                                      options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch]
                        .location != NSNotFound)
                    match = YES;
            if (match)
                [matches addObject:track];
        }
        [matches sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult order = [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
            return order == NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : order;
        }];
        [self notifyChange:NO];
        NSArray *result = [matches copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
                completion(result);
        });
    });
}
- (void)deliverTrackQuery:(NSString *)sql
                arguments:(NSArray *)arguments
               completion:(void (^)(NSArray *))completion {
    dispatch_async(_queue, ^{
        NSArray *result = [self decodeRows:[self query:sql arguments:arguments]];
        [self notifyChange:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
                completion(result);
        });
    });
}
- (void)favoriteTracks:(void (^)(NSArray *))completion {
    [self deliverTrackQuery:@"SELECT t.json FROM tracks t JOIN favorites f ON f.track_id=t.id ORDER BY t.id"
                  arguments:@[]
                 completion:completion];
}
- (void)recentTracks:(void (^)(NSArray *))completion {
    [self deliverTrackQuery:
              @"SELECT t.json FROM tracks t JOIN recent r ON r.track_id=t.id ORDER BY r.played DESC LIMIT 200"
                  arguments:@[]
                 completion:completion];
}
- (void)setFavorite:(BOOL)favorite track:(NSDictionary *)input {
    NSDictionary *snapshot = [[self normalizedTrack:input] copy];
    dispatch_async(_queue, ^{
        BOOL ok = [self execute:@"BEGIN IMMEDIATE" arguments:@[]];
        if (ok) {
            NSString *identifier = favorite ? [self storeExternalTrack:snapshot] : snapshot[@"id"];
            ok = identifier && [self execute:favorite ? @"INSERT OR IGNORE INTO favorites(track_id) VALUES(?)"
                                                      : @"DELETE FROM favorites WHERE track_id=?"
                                   arguments:@[ identifier ]];
        }
        if (ok)
            ok = [self execute:@"COMMIT" arguments:@[]];
        if (!ok && _database)
            [self execute:@"ROLLBACK" arguments:@[]];
        [self notifyChange:ok];
    });
}
- (void)recordPlay:(NSDictionary *)input {
    NSDictionary *snapshot = [[self normalizedTrack:input] copy];
    dispatch_async(_queue, ^{
        BOOL ok = [self execute:@"BEGIN IMMEDIATE" arguments:@[]];
        NSString *identifier = ok ? [self storeExternalTrack:snapshot] : nil;
        ok = identifier && [self execute:@"INSERT OR REPLACE INTO recent(track_id,played) VALUES(?,(SELECT "
                                         @"COALESCE(MAX(played),0)+1 FROM recent))"
                               arguments:@[ identifier ]];
        if (ok)
            ok = [self execute:@"DELETE FROM recent WHERE track_id NOT IN (SELECT track_id FROM recent ORDER "
                               @"BY played DESC LIMIT 200)"
                     arguments:@[]];
        if (ok)
            ok = [self execute:@"COMMIT" arguments:@[]];
        if (!ok && _database)
            [self execute:@"ROLLBACK" arguments:@[]];
        [self notifyChange:ok];
    });
}
- (void)playlists:(void (^)(NSArray *))completion {
    dispatch_async(_queue, ^{
        NSArray *rows =
            [self query:@"SELECT p.id,p.title,(SELECT COUNT(*) FROM playlist_tracks pt WHERE "
                        @"pt.playlist_id=p.id) AS count,COALESCE((SELECT t.json FROM playlist_tracks pt JOIN "
                        @"tracks t ON t.id=pt.track_id WHERE pt.playlist_id=p.id ORDER BY pt.position LIMIT "
                        @"1),X'') AS json FROM playlists p ORDER BY p.created,p.id"
                arguments:@[]];
        NSMutableArray *result = [NSMutableArray array];
        for (NSDictionary *row in rows) {
            id track = [row[@"json"] length]
                           ? [NSJSONSerialization JSONObjectWithData:row[@"json"] options:0 error:NULL]
                           : nil;
            [result addObject:@{
                @"id" : row[@"id"],
                @"title" : row[@"title"],
                @"subtitle" : [NSString stringWithFormat:@"%@ tracks", row[@"count"]],
                @"artwork" : [track isKindOfClass:[NSDictionary class]] ? (track[@"artwork"] ?: @"") : @""
            }];
        }
        [self notifyChange:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
                completion(result);
        });
    });
}
- (void)createPlaylist:(NSString *)name completion:(void (^)(NSString *))completion {
    NSString *title =
        [name isKindOfClass:[NSString class]]
            ? [[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy]
            : @"";
    dispatch_async(_queue, ^{
        NSString *identifier = nil;
        if (title.length && title.length <= 512) {
            identifier = [@"playlist:" stringByAppendingString:[[NSUUID UUID] UUIDString]];
            if (![self execute:@"INSERT INTO playlists(id,title,created) VALUES(?,?,(SELECT "
                               @"COALESCE(MAX(created),0)+1 FROM playlists))"
                     arguments:@[ identifier, title ]])
                identifier = nil;
        } else
            [_errors addObject:MCLibraryError(2, @"Enter a playlist name of 1 to 512 characters.", nil)];
        [self notifyChange:identifier != nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
                completion(identifier);
        });
    });
}
- (void)tracksInPlaylist:(NSString *)identifier completion:(void (^)(NSArray *))completion {
    [self deliverTrackQuery:@"SELECT t.json FROM playlist_tracks pt JOIN tracks t ON t.id=pt.track_id WHERE "
                            @"pt.playlist_id=? ORDER BY pt.position,t.id"
                  arguments:@[ [identifier copy] ?: @"" ]
                 completion:completion];
}
- (void)addTrack:(NSDictionary *)input toPlaylist:(NSString *)playlist {
    NSDictionary *snapshot = [[self normalizedTrack:input] copy];
    NSString *pid = [playlist copy] ?: @"";
    dispatch_async(_queue, ^{
        BOOL ok = [self execute:@"BEGIN IMMEDIATE" arguments:@[]];
        NSString *identifier = ok ? [self storeExternalTrack:snapshot] : nil;
        ok = identifier &&
             [self execute:@"INSERT OR IGNORE INTO playlist_tracks(playlist_id,track_id,position) "
                           @"VALUES(?,?,(SELECT COALESCE(MAX(position),-1)+1 FROM playlist_tracks WHERE "
                           @"playlist_id=?))"
                 arguments:@[ pid, identifier, pid ]];
        if (ok)
            ok = [self execute:@"COMMIT" arguments:@[]];
        if (!ok && _database)
            [self execute:@"ROLLBACK" arguments:@[]];
        [self notifyChange:ok];
    });
}
- (void)removeTrack:(NSString *)trackID fromPlaylist:(NSString *)playlist {
    NSString *tid = [trackID copy] ?: @"", *pid = [playlist copy] ?: @"";
    dispatch_async(_queue, ^{
        BOOL ok = [self execute:@"DELETE FROM playlist_tracks WHERE playlist_id=? AND track_id=?"
                      arguments:@[ pid, tid ]];
        [self notifyChange:ok];
    });
}
- (void)deletePlaylist:(NSString *)identifier {
    NSString *pid = [identifier copy] ?: @"";
    dispatch_async(_queue, ^{
        BOOL ok = [self execute:@"DELETE FROM playlists WHERE id=?" arguments:@[ pid ]];
        [self notifyChange:ok];
    });
}
- (void)pruneArtwork {
    NSMutableSet *used = [NSMutableSet set];
    for (NSDictionary *track in [self decodeRows:[self query:@"SELECT json FROM tracks WHERE path IS NOT NULL"
                                                     arguments:@[]]])
        if ([track[@"artwork"] length])
            [used addObject:track[@"artwork"]];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *file in [fm contentsOfDirectoryAtPath:_artworkDirectory error:NULL]) {
        NSString *path = [_artworkDirectory stringByAppendingPathComponent:file];
        if (![used containsObject:path])
            [fm removeItemAtPath:path error:NULL];
    }
}
- (BOOL)isSafeLocalPath:(NSString *)path {
    NSString *standard = [path stringByStandardizingPath];
    NSString *prefix = [_documentsPath stringByAppendingString:@"/"];
    if (![standard hasPrefix:prefix])
        return NO;
    NSString *relative = [standard substringFromIndex:prefix.length];
    NSString *expected =
        [[_documentsPath stringByResolvingSymlinksInPath] stringByAppendingPathComponent:relative];
    return [[standard stringByResolvingSymlinksInPath] isEqual:expected];
}
- (void)scan:(void (^)(NSUInteger, NSArray *))completion {
    dispatch_async(_queue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray *fileErrors = [NSMutableArray array];
        __block NSUInteger imported = 0;
        BOOL databaseOK = [self execute:@"BEGIN IMMEDIATE" arguments:@[]];
        if (databaseOK) {
            NSMutableDictionary *previous = [NSMutableDictionary dictionary];
            for (NSDictionary *row in
                 [self query:@"SELECT id,path,mtime,size,json FROM tracks WHERE path IS NOT NULL"
                     arguments:@[]])
                previous[row[@"path"]] = row;
            NSMutableSet *seen = [NSMutableSet set];
            NSSet *extensions = [NSSet
                setWithArray:@[ @"mp3", @"aac", @"alac", @"flac", @"wav", @"wave", @"aif", @"aiff", @"m4a" ]];
            NSArray *keys = @[
                NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey, NSURLFileSizeKey,
                NSURLContentModificationDateKey
            ];
            BOOL docsIsDirectory = NO;
            BOOL exists = [fm fileExistsAtPath:_documentsPath isDirectory:&docsIsDirectory];
            NSDirectoryEnumerator *enumerator = nil;
            if (exists && docsIsDirectory)
                enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:_documentsPath isDirectory:YES]
                      includingPropertiesForKeys:keys
                                         options:0
                                    errorHandler:^BOOL(NSURL *url, NSError *error) {
                                        (void)url;
                                        if (error)
                                            [fileErrors addObject:error];
                                        return YES;
                                    }];
            else
                [fileErrors
                    addObject:MCLibraryError(3, @"The Documents folder cannot be scanned.", _documentsPath)];
            for (NSURL *url in enumerator) {
                @autoreleasepool {
                    NSError *error = nil;
                    NSDictionary *attributes = [url resourceValuesForKeys:keys error:&error];
                    if (!attributes) {
                        if (error)
                            [fileErrors addObject:error];
                        continue;
                    }
                    if ([attributes[NSURLIsSymbolicLinkKey] boolValue]) {
                        [enumerator skipDescendants];
                        continue;
                    }
                    if (![attributes[NSURLIsRegularFileKey] boolValue] ||
                        ![extensions containsObject:[[url pathExtension] lowercaseString]])
                        continue;
                    NSString *path = [[url path] stringByStandardizingPath];
                    [seen addObject:path];
                    NSDictionary *old = previous[path];
                    NSNumber *size = attributes[NSURLFileSizeKey];
                    NSNumber *mtime = @([attributes[NSURLContentModificationDateKey] timeIntervalSince1970]);
                    if (old && [old[@"size"] isEqual:size] &&
                        fabs([old[@"mtime"] doubleValue] - [mtime doubleValue]) < 0.000001) {
                        NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:old[@"json"]
                                                                              options:0
                                                                                error:NULL];
                        NSString *art = saved[@"artwork"];
                        if (!art.length || [fm fileExistsAtPath:art])
                            continue;
                    }
                    NSDictionary *metadata = MCReadAudioMetadata(path, _artworkDirectory, &error);
                    NSDictionary *after = [fm attributesOfItemAtPath:path error:NULL];
                    BOOL unchanged = after && [after[NSFileSize] isEqual:size] &&
                                     fabs([after[NSFileModificationDate] timeIntervalSince1970] -
                                          [mtime doubleValue]) < 0.000001;
                    if (!metadata || !unchanged) {
                        [fileErrors
                            addObject:
                                error
                                    ?: MCLibraryError(
                                           4,
                                           @"The audio file changed while it was being scanned; scan again.",
                                           path)];
                        if ([metadata[@"artwork"] length])
                            [fm removeItemAtPath:metadata[@"artwork"] error:NULL];
                        if (!metadata && old)
                            databaseOK = [self execute:@"DELETE FROM tracks WHERE id=?"
                                             arguments:@[ old[@"id"] ]] &&
                                         databaseOK;
                        continue;
                    }
                    NSString *prefix = [_documentsPath stringByAppendingString:@"/"];
                    NSString *relative =
                        [path hasPrefix:prefix] ? [path substringFromIndex:prefix.length] : path;
                    NSMutableDictionary *track = [metadata mutableCopy];
                    NSString *identifier = old[@"id"] ?: [@"local:" stringByAppendingString:relative];
                    track[@"id"] = identifier;
                    track[@"path"] = path;
                    NSData *json = [NSJSONSerialization dataWithJSONObject:track options:0 error:&error];
                    if (!json) {
                        if (error)
                            [fileErrors addObject:error];
                        continue;
                    }
                    BOOL stored = [self
                          execute:@"INSERT OR IGNORE INTO tracks(id,path,json,mtime,size) VALUES(?,?,?,?,?)"
                        arguments:@[ identifier, path, json, mtime, size ]];
                    if (stored)
                        stored = [self execute:@"UPDATE tracks SET path=?,json=?,mtime=?,size=? WHERE id=?"
                                     arguments:@[ path, json, mtime, size, identifier ]];
                    if (stored)
                        imported++;
                    else
                        databaseOK = NO;
                }
            }
            // Check missing files individually: an unreadable subtree must not erase its saved tracks.
            if (exists && docsIsDirectory)
                for (NSString *path in previous) {
                    if ([seen containsObject:path])
                        continue;
                    NSError *error = nil;
                    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:&error];
                    if (!attributes && [error.domain isEqual:NSCocoaErrorDomain] &&
                        (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
                        databaseOK = [self execute:@"DELETE FROM tracks WHERE path=?" arguments:@[ path ]] &&
                                     databaseOK;
                    else if (!attributes && error)
                        [fileErrors addObject:error];
                    else if (attributes && (![self isSafeLocalPath:path] ||
                                            [attributes[NSFileType] isEqual:NSFileTypeSymbolicLink]))
                        databaseOK = [self execute:@"DELETE FROM tracks WHERE path=?" arguments:@[ path ]] &&
                                     databaseOK;
                }
            if (databaseOK)
                databaseOK = [self execute:@"COMMIT" arguments:@[]];
            if (!databaseOK) {
                [self execute:@"ROLLBACK" arguments:@[]];
                imported = 0;
            } else
                [self pruneArtwork];
        }
        [fileErrors addObjectsFromArray:[self takeErrors]];
        NSArray *errors = [fileErrors copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:MCLibraryDidChangeNotification
                              object:self
                            userInfo:errors.count ? @{@"errors" : errors} : nil];
            if (completion)
                completion(imported, errors);
        });
    });
}
- (NSString *)readLyricsAtPath:(NSString *)path {
    if (!path || ![self isSafeLocalPath:path])
        return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] ||
        [attributes[NSFileSize] unsignedLongLongValue] > 1024 * 1024)
        return nil;
    // Read no more than the checked bound, including a file that grows concurrently.
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *data = nil;
    @try {
        data = [handle readDataOfLength:1024 * 1024 + 1];
        [handle closeFile];
    } @catch (NSException *exception) {
        (void)exception;
        [handle closeFile];
        return nil;
    }
    if (data.length > 1024 * 1024)
        return nil;
    for (NSNumber *encoding in @[
             @(NSUTF8StringEncoding), @(NSUnicodeStringEncoding),
             @(CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000))
         ]) {
        NSString *text = [[NSString alloc] initWithData:data encoding:[encoding unsignedIntegerValue]];
        if (text)
            return text;
    }
    return nil;
}
- (void)lyricsForTrack:(NSDictionary *)input completion:(void (^)(NSString *))completion {
    NSDictionary *track = [[self normalizedTrack:input] copy];
    dispatch_async(_queue, ^{
        NSString *path = track[@"path"];
        NSString *text = nil;
        if (!path && track[@"id"]) {
            NSArray *rows = [self decodeRows:[self query:@"SELECT json FROM tracks WHERE id=?"
                                                 arguments:@[ track[@"id"] ]]];
            path = [rows firstObject][@"path"];
        }
        NSString *documentsPrefix = [_documentsPath stringByAppendingString:@"/"];
        if ([[path stringByStandardizingPath] hasPrefix:documentsPrefix] && [self isSafeLocalPath:path]) {
            NSString *directory = [path stringByDeletingLastPathComponent];
            NSString *stem = [[path lastPathComponent] stringByDeletingPathExtension];
            for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory
                                                                                       error:NULL])
                if ([[file pathExtension] caseInsensitiveCompare:@"lrc"] == NSOrderedSame &&
                    [[file stringByDeletingPathExtension] caseInsensitiveCompare:stem] == NSOrderedSame) {
                    text = [self readLyricsAtPath:[directory stringByAppendingPathComponent:file]];
                    break;
                }
        }
        [self notifyChange:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion)
                completion(text);
        });
    });
}
@end
