# Playback

`MCPlayer` implements the shared contract in `INTERFACES.md`. Public mutations
marshal to the main queue. State/change notifications and the 0.5-second progress
notification run on main. Progress is quiet in background while paused.

## Engines and transport

* Local MP3, AAC/M4A, ALAC, WAV and AIFF use AVPlayer and AVURLAsset. The native
  audio format description supplies the displayed format/sample rate/bit depth.
* FLAC uses libFLAC's callback decoder, signed 32-bit interleaved PCM and
  AudioQueue. Source precision is preserved when packing 4–32-bit mono/stereo
  samples into the output word. FLAC stream info supplies the label and duration.
  Multichannel FLAC returns an explicit unsupported-format error. Actual device
  output sample rate/precision may be converted by the iPod audio hardware.
* Online bytes always use MCHTTPClient's verified HTTPS transport, including
  native formats. API credentials are not sent to media hosts. Playback accepts
  official `music.126.net`, `music.163.com` and `music.127.net` CDN hosts and their
  subdomains; redirects must remain HTTPS on those hosts and are limited to four.
* Known-length native streams use `MCNativeResourceLoader`: a custom-scheme
  AVURLAsset receives content type/length and independent byte-range requests
  from the growing spool. At most four range workers return chunks of 32 KiB.
  The resource-loader delegate queue never blocks on future data. Cancelling a
  range does not cancel or corrupt other readers. A seek into undownloaded bytes
  waits for the sequential download to reach them. Containers whose required
  metadata is at the end must wait for that metadata. Unknown-length or
  unrecognized native streams wait for completion and then use the local file.
* Online FLAC parses its header, then waits for approximately five seconds of
  encoded audio on disk before decoding. The watermark uses actual length and
  STREAMINFO duration, bounded to 128 KiB–2 MiB, with a 512 KiB fallback. When
  input runs dry it refills the same watermark; short final tails and completed
  or local files do not wait. Its decoder reads incrementally from the spool and
  ignores artwork/comment metadata. Native FLAC only; Ogg FLAC is not enabled.

## Song cache

`MCAudioCache` keeps completed online files in `Library/Caches/MuyuMusic/Audio`.
The default limit is 256 MiB; settings offer off, 64, 128, 256, 512 and 1024 MiB,
show used bytes and clear songs independently of artwork. The limit persists.
LRU access times survive restart. File operations run on one serial worker;
stores use a hard link or a fixed 64 KiB copy, with room reserved before storing.
Incomplete transfers are never stored. Cache errors do not fail playback.

Every online play still requests current rights from `songURL` before looking
in the cache. The hashed key includes account, full track ID, actual resource
path, format, size and bitrate, excluding expiring URL query credentials. This
is a playback cache, not an offline download library or a substitute for rights.

Leases pin cached files until the last source/decoder releases them. Clear or
lowering the limit hides pinned entries and deletes them after release; pending
bytes count toward usage. Clear and disable invalidate the generation captured
when a download started, preventing its later completion from refilling cache.
Persistent invalid markers prevent reuse of cleared/corrupt data after a crash;
partial stores are discarded on startup. Streaming spools remain separate from
this cache limit: the active track still needs temporary disk space, up to 1 GiB.

## Bounds and lifecycle

Downloads go to a uniquely named temporary disk file with a 1 GiB hard limit.
A source's last owner removes its spool; local files are never removed. Append,
read, length and seek share a mutex/condition and use positional disk I/O, so
readers have independent offsets and never race an underlying file cursor.
HTTP/API lengths and final byte count detect truncated transfers. Disk-full,
size-limit, malformed header/frame, checksum and AudioQueue errors are surfaced.
Temporary files left by an OS kill are cleared by normal iOS temporary-file
maintenance; they are not a persistent download library.

Each decoder owns six AudioQueue buffers, targeting 0.25 seconds each and capped
at 128 KiB per buffer (768 KiB total). At 44.1 kHz stereo this is 529,200 bytes,
or 1.5 seconds of signed 32-bit PCM. Actual FLAC frames are accumulated across
buffer boundaries, so allocated capacity is really used rather than submitting
one short FLAC frame per large buffer. Four filled buffers start/restart output;
EOF flushes the exact short tail. After an underrun the output control queue
pauses without discarding samples, then resumes after refilling. The decoder
waits when all slots are busy, providing PCM backpressure. No entire-song NSData
or PCM array is retained. libFLAC owns bounded frame/bit-reader storage; the native framework
controls its own normal media buffers. A maximum of two FLAC decoder operations
can run while a replaced engine unwinds. Network download is independent of PCM
backpressure, so a forward seek cannot deadlock waiting for bytes that a paused
decoder prevented from downloading. Disk writes provide transport backpressure.

Seek/cancel interrupts blocking spool reads and wakes buffer waiters. AudioQueue
commands and disposal run on a dedicated serial control queue; no mutex is held
while calling stop/reset/dispose. Queue callbacks only update buffer ownership
and signal waiters. Decoder/source callbacks are marshalled to main, and a
session generation rejects stale results after queue edits or track changes.
AVPlayer seeks also carry a generation to reject an older seek completion.

There is a 30-second no-data timeout, a 15-second active AudioQueue stall guard,
and a five-second AudioQueue drain guard. Paused output does not trigger the
active stall timeout. Native range readers poll in cancellable 100 ms waits.

## Queue, recovery and system integration

Queue removal/movement retains the selected track; removing it selects its next
neighbor or clears an empty queue. Shuffle visits each item once before repeat
all starts a new cycle and keeps bounded previous-track history. Repeat one
applies to automatic completion. Previous restarts the current track after three
seconds. Invalid/empty queue actions are safe.

Transient online download/access failures refresh `songURL` and restore the
retained playback position, with at most two retries per selected track and
0.75/1.5-second delays. Expired responses are treated the same way. Format/decode,
rights, unsupported-URL and storage errors do not loop. Explicit Retry resets the
budget. Selecting or editing the queue invalidates obsolete retry callbacks.

The audio session is Playback. Pause/resume, audio interruptions, lost headphone
routes, media-services reset, iOS 7 remote UIEvents and Now Playing metadata are
implemented. Local cover images are reduced to a 256-pixel thumbnail for Now
Playing. The application target must declare `UIBackgroundModes = audio` and
forward remote events through `handleRemoteEvent:`; the root application does so.

## Verification and remaining acceptance

Run `tests/playback.sh` (or `PLAYBACK_SANITIZE=1 tests/playback.sh`) and
`tests/audio_cache.sh`. The necessary
host test is `tests/playback_core.c`, compiled with
`Sources/Playback/MCPlaybackCore.c` and pthreads. It exercises queue edits,
repeat/shuffle termination, seek clamping, exact signed PCM packing, incremental
producer/consumer reads, independent forward/backward native ranges,
cancellation wakeups, temporary-file removal, storage caps, truncated input,
prebuffer watermark, seek cancellation and short final tails. PCM staging checks
uneven 4096/4608-frame fragments, exact signed 24-bit stereo samples across
output boundaries, the final short buffer and high-rate capacity bounds. Cache tests use
the production Objective-C implementation for LRU, limits, restart, pin release,
clear/store races, late download completion, corrupted files and storage errors.
It passes with `-Wall -Wextra -Werror` and AddressSanitizer/UndefinedBehaviorSanitizer.
All playback Objective-C and C sources also compile for ARMv7 against the actual
iPhoneOS7.1 SDK with an iOS 7 deployment target.

USB inspection has identified iPod4,1 / 7.1.2 (11D257) and real FLAC temporary
files. The user reported smooth playback after the earlier track was fully
cached. This is limited evidence from the earlier build; the new prebuffer and
persistent song cache still require audible device checks. Host tests do not
verify AVPlayer resource-loader behavior on the unofficial iOS 7 firmware,
AudioQueue conversion/scheduling/drain behavior, audible format playback,
long-duration memory use, lock-screen controls, network expiry during real
account playback, interruption/resume or headphone routing. These remain device
acceptance checks, including progressive MP3/AAC, M4A with tail metadata, FLAC
seek while downloading, paused seek, cancellation during a slow request and
rapid track changes.

## Release behavior (1.1.0)

Continuous playback snapshots and diagnostic counters have been removed. Startup removes the legacy PlaybackDiagnostics.json file; normal errors, buffering state and retries remain. PCM buffering and queue recovery are unchanged.
