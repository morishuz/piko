# Diagnostics

Diagnostics are **off by default**. The app makes no internet connections.
With recording off, no new diagnostic events are retained in memory or on disk.
Saving an on/off preference does not record device activity.

## Collect a report

1. Open Settings → Diagnostics and enable **Record diagnostics**.
   A confirmation explains what is saved locally. Cancel leaves recording off.
2. Optionally choose **Delete Diagnostics** before a controlled test.
3. Connect and reproduce the issue, then export from Settings.
4. After a crash with recording enabled, reopen once and export before another
   enabled launch rotates the journal. Describe the device, operation, expected
   result, and observed result separately when sharing a report.
5. Turn recording off when finished. This stops new events immediately and turns
   off detailed recording too. Existing logs remain available to export or clear.

Both checkboxes are in Settings; there is no main-window status notice. The
recording choice is remembered across restarts.

After consent, the app retains `current.jsonl` and `previous.jsonl` under
`~/Library/Application Support/Piko/Diagnostics`.
Each session retains at most 4,096 events; exports report discarded events.
Launching with recording off neither creates nor rotates journals. Existing logs
from opted-in sessions remain until explicitly cleared.
Delete Diagnostics removes both sessions and resets the in-memory ring. When
recording remains on, a fresh journal starts and ongoing operations may record
new events. When off, clearing does not create another journal.
Exported copies are separate files and must be deleted separately.

Schema-7 reports contain current-launch events, the previous recorded session
when available, and a `savedSession` when this launch has not enabled recording.
Saved sessions retain their original build/OS metadata. Reports identify backend,
app version/build/source revision, dirty flag, macOS version and whether saved
sessions ended cleanly or were truncated. Stopping recording without quitting
leaves no clean-exit marker; its absence alone is not proof of a crash.

## Detailed recording for filename or folder problems

1. Enable basic recording, then turn on **Include filenames and folder paths**
   and accept the separate privacy confirmation. This is off by default and its
   choice persists while recording remains enabled. Enable it before connecting so the device model,
   firmware and USB target can be associated with the subsequent attempt.
2. Connect the affected device, open the folder and reproduce the warning. No
   move or deletion is necessary to investigate an unavailable listing entry.
3. Choose **Export Diagnostics…** promptly, then share that JSON if desired.
   After quitting/crashing, reopen once and export: recorded details are retained
   in the immediately previous session too. Old reports cannot recover names that
   were never recorded.
4. Turn detailed recording off when finished to stop new filename/path collection,
   or turn off all recording. Previously collected details remain; use
   **Delete Diagnostics** to remove the saved current/previous records as well.

Detailed reports include remote folder paths, advertised object handles, returned
filenames, storage/parent IDs, object format, protection, size and raw timestamps,
plus device model/manufacturer/firmware and the discovered USB registry target.
Move records include source and destination paths before the command. Session
and device correlation IDs separate old handles from later connections.

An object-details error includes the requested handle and parent folder even when
GetObjectInfo returns no filename. A previous successful metadata record from
that same session may supply its name. If the device never supplied the name,
we cannot infer it. **Export Diagnostics…** follows the filenames checkbox:
when checked it includes recorded details; when unchecked it filters them out
of all current and saved sessions. Turning off all recording also unchecks the
filenames option, so subsequent exports omit those details. Neither report includes file contents, raw USB payloads,
local Mac paths, keywords or serial-number fields.

Collection is bounded: 4,096 events per session, at most 64 handles per enumeration
record (with totalHandles for the full count), 512 UTF-8 bytes per remote path,
256 per filename, and shorter model/date fields. An ellipsis marks shortened text;
control characters are replaced. Export promptly to avoid older context being
rotated out by subsequent activity. Standard-report sequence gaps can represent
omitted detailed records as well as the reported ring-buffer overflow.

## Recorded information

- App connect/disconnect, listing, upload/download outcomes and stop requests.
- MTP operation/response/transaction codes, failure phase, byte counts, duration,
  malformed-header numeric fields, and session release.
- Apple registry discovery, interface open/release, packet transfers, and raw
  signed IOReturn errors in `appleUSBError`. Shared `usbStatus` values use a
  stable normalized vocabulary.
- Process-local transport/session/transfer/recovery correlation counters, intended
  connection retry delays, and fresh-session attempts. File transfers are not replayed.
- Selected-interface VID/PID, interface number and packet sizes when available.

Full-size successful reads and continuing writes are batched in groups of up to
64 calls, retaining byte totals and sample counts. Byte counts do not prove integrity.
Discovery/open breadcrumbs are persisted synchronously. Routine events are batched;
critical lifecycle events flush in order. A sudden crash may lose the last queued
routine events, but a partial trailing journal line does not discard its valid prefix.

Ordinary events use enums and numbers; unknown NSError descriptions are never
recorded. Optional detailed metadata is collected only while the setting is on.
Timing, sizes, VID/PID and OS/build versions reveal technical usage information.
Journals and exports are not encrypted. The app makes no internet connections;
sharing requires manually exporting a file and sending it outside the app.

Historical enum values for old discovery/cancellation/reset reports remain decodable.
They are schema compatibility data. Ordinary Apple USB error cleanup closes the
interface and emits `closeOnly`. Explicit transfer cancellation can use the MTP
control channel; ranged transfers normally stop at a completed part boundary.
Pipe I/O has a 15-second timeout. Stop After Current File does not immediately
abort device I/O.

The app records `responderReset` command/completion records for the selected-interface
class reset after an accepted move produces an invalid listed object. `moveRecovery`
records a delayed recheck and, if needed, fresh-session verification. Completion
without failure means the move was verified; `deviceRejected` means it is still listed only at its source,
and other failures mean the result or recovery could not be verified. A reset
acknowledgement alone does not establish successful recovery. Detailed folder and
object records show both locations after recovery. No file operation is replayed,
and none of these events represents a whole-device USB reset.

The app records an explicit reset control STALL as `responderReset` completion
with `usbStatus: -9` and `failure: deviceRejected`. It follows this with one
GetStorageIDs transaction on the same session. A successful response retains
the connection; `moveRecovery` still completes with a failure because the move
and full listing remain unverified. A failed liveness check retires the session.
No additional reset is sent on a transport that already rejected it.

## Verification

`swift test` covers default-off and declined consent, persistent opt-in, disabled
launches without journal writes, concurrent recording gates, USB batch boundaries,
privacy filtering, crash-truncated
journals, previous-session rotation, transfer correlation and close-only cleanup.
Use [the hardware procedure](TESTING.md) for device evidence.
