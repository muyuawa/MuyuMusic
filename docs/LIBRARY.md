# Offline library

`Sources/Library/MCLibrary.h` implements the contract in `docs/INTERFACES.md`; `MCLyrics.h` provides the standalone LRC parser. The implementation uses ARC, Foundation, dispatch, SQLite, AVFoundation, CoreMedia, CoreGraphics and ImageIO. It does not depend on UIKit or any account/network state. All implementation files compile against the iOS 7.1 SDK for ARMv7 with an iOS 6.0 deployment target.

The singleton stores its SQLite database in `Library/MuyuMusic/music.sqlite`. `initWithDatabasePath:documentsPath:` supports isolated host fixtures. Opening the database, all queries and mutations, recursive enumeration, metadata extraction and lyric reads execute on one serial worker queue. Every completion and `MCLibraryDidChangeNotification` arrives asynchronously on the main queue. Callers can enqueue a read after a mutation to observe its committed result.

SQLite uses foreign keys, WAL and transactions. Local track IDs are `local:` followed by the path relative to Documents, so metadata updates and repeated scans preserve identity. Renaming/moving a file creates a new identity. Online IDs remain strings, including decimal values larger than 64 bits. Favorites, playlist membership and a distinct recent-play list (latest 200) can retain complete online track dictionaries offline. Local file deletion removes the corresponding local favorite, recent entry and playlist memberships by foreign-key cascade. Duplicate playlist additions preserve the original ordering.

## Scanning and metadata

`scan:` recursively imports MP3, AAC, ALAC/M4A, FLAC, WAV/WAVE and AIFF/AIF files. It skips symlinks, including directories, and removes previously imported paths that have become symlink aliases. Size and modification time identify unchanged files. Files changed during extraction are reported for a later retry. Missing files are checked individually so an enumeration or permissions failure does not erase an unreadable subtree. A changed file that can no longer be parsed is removed from the library.

Native media uses AVFoundation for title, artist, album, duration, sample rate and available bit depth; ALAC is identified from its actual audio format. Missing text falls back to the filename and empty artist/album. Native artwork is read separately from bounded ID3 APIC/PIC frames, MP4 `covr` atoms, or ID3 chunks in WAV/AIFF. The implementation never requests AVFoundation's artwork-value accessor.

FLAC metadata is read incrementally using file seeks. STREAMINFO provides duration/rate/depth, Vorbis comments provide title/artist/album, and PICTURE provides artwork. Comment blocks are capped at 1 MiB and picture blocks at 4 MiB. Larger optional blocks are skipped without allocating their size. Every length is checked against the remaining file; loops, nesting and frame counts are bounded. The parser validates the metadata structure and initial audio frame fields, not every compressed audio frame. Playback must still report subsequent bitstream errors. A valid zero STREAMINFO total sample count imports with duration 0 and preserves its sample rate and bit depth; playback can decode until EOF.

Artwork is decoded through ImageIO into JPEG thumbnails with a maximum dimension of 256 pixels. Encoded inputs above 4 MiB and images above 40 million pixels are omitted. Cache files live under `Library/Caches/MuyuMusic/Covers/<database namespace>`, outside scanned Documents. A scan regenerates a missing cached cover and prunes unreferenced thumbnails after commit. Unsupported ID3 unsynchronization/extended-header artwork is omitted; this does not prevent importing playable audio. Full-size artwork is not retained.

Search is local, case/diacritic insensitive across title, artist and album. It treats `%` and `_` literally rather than as SQL wildcards. SQLite and search work run on the worker queue.

## Lyrics and errors

`lyricsForTrack:` finds a case-insensitive `.lrc` sidecar with the same basename in the local track's directory. Reads are capped at 1 MiB and reject symlinks escaping Documents. UTF-8, UTF-16 and GB18030 text are supported. The callback returns nil when no usable sidecar exists. Online lyric fetching/caching belongs to the network/player layers.

`MCLyrics` expands multiple timestamp tags, sorts stably, accepts fractional seconds and applies the last `[offset:milliseconds]` tag globally by adding its signed offset to each timestamp. `indexAtTime:lines:` uses binary search and returns -1 before the first line or for empty input.

`scan:` returns an array of actual `NSError` objects, including paths for malformed/unreadable media and database failures. Mutation/query methods have no error parameter in the shared interface, so failures are surfaced in `MCLibraryDidChangeNotification.userInfo[@"errors"]`. Invalid playlist names complete with nil. Failed multi-statement mutations roll back completely. The UI should display each error's `localizedDescription`, not join NSError objects as strings.

## Verification

Run `./tests/library.sh` on this macOS host. The test executable uses the production Foundation/SQLite/media code and temporary real files rather than mocks. Latest result: **227 checks passed**. Coverage includes LRC offsets/multiple tags/boundaries; recursive WAV and FLAC metadata; cover resizing and cache regeneration; valid unknown-duration FLAC and corrupt rate/depth/channel/sync fields; corrupt/oversized headers; update/delete/dedup behavior; literal Unicode/wildcard search; persistent online/local favorites, recent plays and ordered playlists; long IDs; foreign-key rollback; symlink replacement and lyric containment; asynchronous main-queue completions; and database-open failure.

The initial test was observed failing for the missing parser; after implementing the parser it failed for the missing library. The cache-regeneration and unknown-duration FLAC regressions were also observed failing before their fixes.

Strict SDK checks passed for `MCLyrics.m`, `MCMetadata.m` and `MCLibrary.m` using:

```sh
scripts/cc-ios -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -Wno-unused-command-line-argument -fsyntax-only Sources/Library/<file>.m
```

No physical device runtime or long-duration memory measurement has been performed. Native-format decoding and metadata behavior still need verification on the actual iOS 6 firmware, including real MP3/AAC/ALAC/AIFF collections and their tag variants. Host tests validate WAV plus the bounded FLAC metadata path; their short FLAC fixture is a metadata/parser fixture, not a full playback acceptance file.
