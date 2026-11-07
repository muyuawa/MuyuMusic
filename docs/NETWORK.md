# Direct NetEase adapter

`MCAPI` uses native Objective-C/CommonCrypto and sends encrypted requests directly to `https://interface3.music.163.com/eapi/…`. No server, embedded JavaScript runtime, fabricated catalog, IP spoofing, media substitution, DRM removal, or rights bypass is used. This unofficial protocol can change independently of the app.

## Primary sources

Inspected 2026-11-03:

- [YesPlayMusic playlists](https://github.com/qier222/YesPlayMusic/blob/master/src/api/playlist.js) explains why `trackIds` must be fetched separately from incomplete playlist `tracks`; [authentication](https://github.com/qier222/YesPlayMusic/blob/master/src/api/auth.js) documents QR statuses.
- [HyPlayer EAPI contracts](https://github.com/HyPlayer/HyPlayer.NeteaseProvider/tree/c11cd1278ed0b3a232242eded7e6d14d1c9f8683/HyPlayer.NeteaseApi) independently confirms QR and playback URL paths and trial metadata.
- [Current API crypto](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/984cc021b8598cf94c22134f32a8426887fb2de7/util/crypto.js), [envelopes](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/blob/984cc021b8598cf94c22134f32a8426887fb2de7/util/request.js), and [endpoint modules](https://github.com/NeteaseCloudMusicApiEnhanced/api-enhanced/tree/984cc021b8598cf94c22134f32a8426887fb2de7/module). Some defaults now use newer protocols; EAPI availability was separately checked against the real service.

EAPI compatibility uses UTF-8 JSON, MD5 of `nobody` + `/api/…` path + `use` + JSON + `md5forencrypt`, then AES-128-ECB/PKCS#7 with protocol key `e82ckenh8dichen8`. Uppercase ciphertext hex is submitted as form field `params`. These operations implement the service protocol; TLS supplies transport security. Requests set `e_r=false`; uncompressed encrypted JSON responses are also accepted. JSON must be a dictionary with a numeric service code.

| Feature | Protocol path (`/api/` is rewritten to `/eapi/` in the URL) |
| --- | --- |
| Search / discover | `/api/cloudsearch/pc`, `/api/personalized/playlist` |
| Playlist / detail batches | `/api/v6/playlist/detail`, `/api/v3/song/detail` |
| Album / artist / albums | `/api/v1/album/{id}`, `/api/v1/artist/{id}`, `/api/artist/albums/{id}` |
| User playlists / likes | `/api/user/playlist`, `/api/song/like/get`, `/api/radio/like` |
| Playback / lyrics | `/api/song/enhance/player/url/v1`, `/api/song/lyric` |
| QR / poll | `/api/login/qrcode/unikey`, `/api/login/qrcode/client/login` |
| Refresh / account | `/api/login/token/refresh`, `/api/w/nuser/account/get` |

IDs remain decimal strings, using `NSNumber.stringValue` rather than 32-bit conversion. Interpolated IDs are validated as ASCII digits. Durations convert milliseconds to seconds. Search returns 30 items and `more`. Sequential detail batches contain at most 100 songs and restore playlist ID order; invalid or incomplete ID lists fail explicitly. Omitted individual details use real metadata already returned in the playlist where possible; remaining unavailable IDs are reported with the total count. The UI shows available real songs plus a loaded/total/missing notice and Retry. No invented metadata enters the queue, and playback rights are checked normally. Playlist and liked-music results share this collection contract. Limits are 10,000 tracks, 10,000 user playlists and 2,000 artist albums, with errors instead of silent truncation. Artist tracks are the service's hot-song list (normally 50); albums and user playlists are paginated fully within these limits.

## Transport and sessions

The app links pinned libcurl/mbedTLS and uses bundle `cacert.pem`, certificate and hostname verification, TLS 1.2 minimum for HTTPS, and no automatic redirects. NetEase and ordinary transport remain HTTPS-only. Missing CA data is an error for HTTPS. A redirect's lower-case `location` and numeric `status` are exposed for playback to validate, limit, and follow explicitly. The audio caller requires a complete 2xx response and rejects partial 206 responses; 3xx complete for caller handling and 4xx/5xx fail.

Selected custom sources use `sourceRequestURL` for control and `sourceStreamURL` for audio. The default-enabled `music.sources.httpsOnly` preference requires HTTPS on both paths and audio redirects; disabling it permits HTTP for subsequent custom requests. HTTPS certificate/hostname validation remains enabled. Script downloads and repository URLs remain HTTPS-only. Streams always strip Cookie/Authorization; custom control requests receive only source-supplied credentials, never the NetEase session.

Three curl workers bound active transfers. Ordinary bodies are limited to 8 MiB after decompression; headers to 64 KiB. Streaming passes blocks ≤32 KiB directly to playback without whole-song buffering. Connect timeout is 15 seconds; low-speed timeout 30 seconds; ordinary total timeout 40 seconds. JSON encryption/parsing has one background queue. Public API and ordinary HTTP completions arrive on main; all stream callbacks run on a worker. Stream byte pointers are valid only during their callback.

There is no shared cookie jar. Cookies/authorization may be sent only to exact API hosts `music.163.com`, `interface.music.163.com`, and `interface3.music.163.com`; every stream strips them regardless of host. `cancel` is thread-safe, checked before opening queued connections and through active progress/write callbacks. Returning `NO` from data also cancels. One terminal completion follows shutdown; a callback already executing may finish after `cancel`, so callers retain their stream state until completion.

Only `MUSIC_U`, `MUSIC_A`, `__csrf`, and `NMTID` from service response cookies are accepted. Sessions/profile use Keychain generic-password service `com.muyu.cloudmusic.session`, account `netease`, accessible after first unlock on this device only. A stable random client ID in preferences is not a credential. Cookies, keys and QR payloads are never logged. Logout deletes local secrets and advances generations; new authorization invalidates older account responses, new QR creation invalidates older polls, and a delayed refresh cannot delete a newer session.

QR payloads are rendered locally from `https://music.163.com/login?codekey=…`. Status 800 means expired, 801 waiting, 802 awaiting confirmation, 803 authorized. Authorization requires a valid session and successful Keychain persistence, then fetches profile. Refresh revalidates profile; definitive unauthenticated refresh clears state. `loggedIn` denotes a saved MUSIC_U, not recent server validation.

Trial-only metadata, missing/denied URLs, and non-NetEase media hosts fail. Only `*.music.126.net`, `*.music.163.com` and `music.163.com` playback URLs are accepted. Service HTTP CDN/artwork links are upgraded to verified HTTPS, with no HTTP fallback. Requested quality is not promised: format/bitrate come from the response; bit depth/sample rate are included only when actually supplied.

## Necessary checks and evidence

```sh
tests/network_run.sh             # crypto, parsing, batching and login races
tests/network_transport.sh       # real curl with temporary local TLS fixture
tests/network_live.sh            # optional full public catalog probe; never with saved session
tests/network_bundled_tls.sh     # pinned host TLS build, transport checks, one live search
```

The helper suite observed 13 initial failures before implementation. It covers an independent fixed EAPI vector, 64-bit IDs, malformed/null JSON, trial denial, CDN trust, 205-song ordering, partial/all missing details, genuine playlist metadata fallback, malformed detail responses, transport errors, empty playlists, account errors, main completions, album pagination and stale refresh/QR cancellation. The local transport fixture covers trust rejection, HTTP refusal, cookie/auth stripping, 8 MiB bounds, chunks/cancel, callback threads and explicit redirects. Its CA override exists only in a test subclass. `network_bundled_tls.sh` links the production adapter to host builds of pinned curl 8.23.0 and mbedTLS 3.6.7; default scripts otherwise use system libcurl.

Actual public service evidence on 2026-11-03: search 30 songs with more; discover 30 playlists; playlist `19723756` 100 tracks; album 15 tracks; artist 50 hot songs/142 albums; lyrics 3,039 UTF-8 bytes; QR creation and unscanned status 801. Requested lossless returned trial-only metadata and was correctly rejected with rights error -20. Unsigned user playlists returned login-required 301. All three network implementations compile for ARMv7 against SDK 7.1 with `-Wall -Wextra -Werror`.

Pinned host backend verification completed with `curl/8.23.0 mbedTLS/3.6.7`, zero transport failures (including untrusted-certificate rejection), and an actual public encrypted search returning 30 items. The host build uses its native clock; the target platform-clock shim is verified separately by the root build.

QR authorization/803, target Keychain persistence, account mutations/private collections, entitled FLAC access, long playback and physical-device TLS remain unverified. The host TLS build validates the backend selection and calling code, not execution on the unofficial iOS firmware.
