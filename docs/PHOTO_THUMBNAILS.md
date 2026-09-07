# Photo and video thumbnails

Photos and videos appear as small inline list thumbnails or in an image grid. Use the segmented list/grid switch in the device toolbar. The list
is the default; both views share file ordering, selection, context actions and
Finder/device drag and drop. Grid images fit their bounds without cropping.

Visible photos and videos automatically request existing device thumbnails after scrolling
settles. Files appear immediately with their normal icons; previews replace those
icons as they arrive. Missing previews remain ordinary icons, without spinners,
error badges or popups. There is no directory-wide scan or video extraction.

Right-click one or more photos and choose **Generate Thumbnails** to create missing
previews from their originals. The menu gives the eligible count and estimated
bytes to read. This action uses the normal verified download queue and its progress
and cancellation controls. Each original is downloaded to a private temporary
folder, downsampled, then removed. Original downloads are never automatic.

## Device-provided video previews

Video preview sources are tried conservatively:

1. Prefer a `.THM` companion in the same folder and session with the same filename
   stem (case insensitive). Exactly one video and one companion must match. The
   companion must have a known, nonzero size of at most 512 KiB. We do not guess
   across GoPro prefixes or reuse another chapter's thumbnail. No extra directory
   scan is performed; only objects exposed in the current listing are considered.
2. Otherwise, use MTP `GetThumb` when the device advertises it and the video's
   metadata advertises a bounded JPEG/PNG thumbnail.
3. If no GetThumb image is returned, use MTP representative sample properties
   when both required operations and the format's sample properties are supported.
   Probe support once per format per connection, then request only a JPEG/PNG
   sample with a nonzero advertised size within 512 KiB. The actual byte array
   is independently bounded and checked before decoding.

All paths share the photo cache, scheduling, pause behavior and decoder. Invalid
image bytes leave an icon without further fallback. Video previews have a small
play badge. Supported video filename extensions are MP4, MOV, M4V, AVI, 3GP, 3G2,
MPEG, MPG, WMV, MKV, WebM and GoPro 360. Recognition alone does not imply that a
device provides a preview. The photo-only Generate Thumbnails action never reads
a video, LRV proxy or embedded video metadata to extract a frame.

**Platform support:** GoPro documents THM files as JPEG thumbnails. They can be
used here when exposed through the camera's MTP listing; the app does not use
GoPro Wi-Fi APIs. Other cameras can use the same unambiguous companion convention
or standard MTP previews. Android gallery thumbnails live behind media APIs and
are not automatically exported over USB: the Android reference MTP code inspected
for this release serves image formats, not video thumbnails. OEM implementations
may differ. Devices without an exposed preview keep icons. iPhone/iPad-specific
media protocols are outside this MTP app's support.

Sources: [GoPro media files](https://gopro.github.io/OpenGoPro/),
[Android MTP thumbnail implementation](https://android.googlesource.com/platform/frameworks/base/+/master/media/java/android/mtp/MtpDatabase.java),
[MTP property definitions](https://android.googlesource.com/platform/prebuilts/fullsdk/sources/+/refs/heads/androidx-graphics-release/android-34/android/mtp/MtpConstants.java),
[reference MTP property transactions](https://github.com/libmtp/libmtp/blob/master/src/ptp.c).
These references inform protocol support; no third-party runtime was added.

## Responsiveness and limits

- Device-thumbnail requests run one at a time after a 300 ms scrolling delay,
  with a 75 ms gap between requests. Only visible photo/video candidates are scheduled,
  capped at 128. Optional work is refused immediately when the device is busy.
- Navigation, transfers, a disappearing view, disabling automatic thumbnails or
  quitting cancels unstarted work and discards late results. A started protocol
  transaction finishes its response before the connection is reused. Thumbnail
  cancellation does not send USB cancel/reset.
- A device-thumbnail request taking more than one second pauses further automatic
  requests on that connection. Errors also pause loading. Use **Resume Automatic
  Thumbnails** in a file's context menu to resume. Right-click the list/grid switch
  to turn **Load Device Thumbnails Automatically** off or on.
- Each request revalidates the selected object's metadata without listing other
  folders. Photos use MTP `GetThumb`; videos use the preview sources above.
  Companion reads use a bounded GetObject request for the THM file only.
  Supported photo candidates are
  JPEG, PNG, HEIC/HEIF, GIF, BMP, TIFF and DNG; devices must return a JPEG or PNG
  thumbnail. Unsupported operation and ordinary framed refusals are cached as
  missing previews, preserving the connection.
- Advertised and actual thumbnail payloads are capped at 512 KiB. ImageIO checks
  dimensions before decoding on a utility task: device thumbnails are limited to
  4096 pixels per side and 4,194,304 pixels. Output is at most 256 pixels per side.
- Explicit generation allows originals up to 256 MiB each, 32,768 pixels per side
  and 100 megapixels. ImageIO handles supported formats and orientation off the
  main actor. Unsupported or corrupt images keep icons; other selected photos can
  still complete. No custom format parser or external image dependency is added.
- Generated originals use the existing transfer engine's byte verification,
  staging, cancellation and recovery. Devices with ranged reads can cancel between
  range requests; others stop after the current file. Completed thumbnails stay
  cached. Session failures follow existing recovery rules without replaying the
  generation batch.
- Each device cache holds at most 128 results and 8 MiB of decoded images. Missing
  previews count as results too. Connection changes clear the cache; keys include
  storage, session identity and file metadata. There is no persistent disk cache.
  Evicted images may need fetching again when revisited.
- An incomplete, oversized or malformed device-thumbnail response follows the
  existing session disposal rules. An idle browser asks for reconnection without
  retrying or reopening the device automatically. Foreground recovery remains
  responsible if already underway.

Thumbnail I/O stays off the UI thread, but MTP serializes operations on each
device. A slow thumbnail already in progress can delay that device's next
operation. The one-second threshold stops subsequent requests; it cannot safely
interrupt an active response. The transport retains its existing 15-second timeout
per USB call, which is not a total deadline for a complete thumbnail. Other device
sessions remain independent.

## Validation

Synthetic tests cover automatic GoPro companion association,
GetThumb video previews, representative sample capability probing and connection
cache reset, unsupported/non-image/oversized samples, malformed property arrays,
exact companion read lengths, cancellation between property requests, and session
loss without fallback. Tests assert that no video object is downloaded. Native
list/grid renders include video badges and unchanged selection.


Hardware-free tests exercise fragmented MTP containers, capability and metadata
checks, response limits, framed refusals, truncated responses, cancellation at
both transaction stages, busy rejection and stale-session handles. Scheduler tests
cover coalesced scrolling, overlapping viewports, bounded cache eviction, slow-device
pausing, foreground priority and view replacement. Native AppKit tests cover grid
selection, visible-item reporting, context menus, drop destinations and file
promises, plus synthetic list/grid renders. Generation tests cover verified reads,
missing-only batches, corrupt images, stop-after-current-file and temporary cleanup.

Thumbnail availability and latency depend on device firmware. Validate previews
and interactions on physical devices using [the testing procedure](TESTING.md).

The test-only simulated device can return a small JPEG/PNG already uploaded into
its in-memory storage (at most 512 KiB); it never reads another local file to
produce a preview.
