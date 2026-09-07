# Recoverable device bin

Drag remote files or folders onto the single bin icon, or right-click and choose
**Delete (Move to Bin)…**. Click the bin icon to see the original files and
folders, with their names, types, sizes and original locations. Right-click a
selection and choose **Restore to Original Location…** or **Delete Permanently…**.
The Bin view also offers Restore and Empty Bin. Duplicate names remain separate
entries, distinguished by Original Location. Opening a binned folder shows its
contents; Up returns to the bin without exposing its recovery folders. A missing original parent
is recreated after confirmation; a detected name conflict stops restoration.
Clicking Bin always opens its contents, even when files are selected; it never
changes into a delete action. The larger Bin target highlights blue with “Move
to Bin” during an accepted drag. A blue badge counts visible top-level items
(one folder counts once). Empty recovery records do not count. Zero has no
badge; a failed lookup leaves the count unknown and explains why the Bin is
unavailable. Counts update on connection, Bin access, Bin operations and Refresh.
Inside a binned folder, the icon returns to the overview. Up from the overview
returns to the storage root.

## Connection preparation and ownership

Every storage is checked independently before writes become available. A new Bin
is a visible `/Piko Bin` at the storage root; no Documents folder is required.
`Piko-Bin.json` contains a format identifier, version, UUID and storage identity.
It is written and read back before preparation succeeds. No moves or deletions
are tested during connection. An occupied name, including a case variant or a
regular file, gets a UUID-suffixed alternative. Existing names are never adopted
just because they look like a Bin. Only verified Bin roots are hidden from the
app's ordinary folder lists; the device file browser can still see them.

An existing, recognised Bin is reused without any new write test. This allows
Empty Bin to free space on a full storage, if permanent deletion is supported.
If lookup, creation or initialisation fails, the Bin icon is grey and inert,
and uploads, moves, Bin drops and Move to Bin are blocked for that storage.
A “Browsing only” message explains the failure. Downloads still work, including
copies out to another writable device. Refresh does not retry creation; reconnect
rechecks preparation. No manual setting, model blacklist or permanent ban is
stored. The gate is a prerequisite, not proof that every folder allows every
write: existing operation checks, read-only reports and move recovery still apply.
A failed preparation may leave its newly created directory for manual inspection.

The Bin and folders containing it cannot themselves be moved or binned.

This is a Piko folder, not Android MediaStore trash. Items occupy device
storage until permanently deleted. After disconnecting, a file browser can access
and restore them. Gallery visibility depends on the device's media indexing;
no `.nomedia` or hidden-folder trick is used. Cameras may not expose arbitrary
folders in their own UI, and may not support these operations at all.

## Recovery format

Each entry is named `Piko-<original-name-label>-<UUID>` and contains:

- `Restore.json`: versioned, immutable source path, original filename, kind,
  size, timestamp, date binned, and device/storage description.
- `Restore-info.txt`: readable original location and manual restore instructions.
- `Files/<original name>`: the original file or entire folder tree.
- `Move-check.txt`: a tiny disposable file used to check moves in both directions.

Metadata is uploaded and downloaded for byte-for-byte verification before the
original is touched. The bin uses no persisted MTP handles: those are resolved
fresh after reconnect. Reported manufacturer/model/serial, volume description,
label and capacity detect storage mismatches; they are not guaranteed globally
unique identifiers. Recovery data lives on the device, so it can be read from
another Mac without a local database. Source paths and device identity appear
in those visible recovery records. Diagnostics include preparation state and item
count; paths and filenames require the existing detailed-recording opt-in.

The Files folder is authoritative after interruption. If the
original move succeeds but its reply is lost, reconnect and restore
from the payload. Do not repeat Move to Bin on an old selection. If a preliminary
probe fails, the original remains in its source folder; the entry may contain a
leftover probe. If a probe restores the connection using a new session, the app
stops before moving the original and refreshes the listing. Select the original
again to retry. Empty entry folders mean preparation was interrupted, or the
item was restored/moved manually. They are retained with their notes but omitted from the normal bin file list.
The bin shows a retained-record count, and Empty Bin includes these records.
Unrecognized entries, extra files and damaged metadata remain visible as their
actual files/folders for inspection, with Restore disabled. Empty Bin excludes
them; in a marker-owned Bin they can be deliberately selected for permanent
deletion. Listing errors are
reported rather than treated as an empty Bin.

Manual restore: move the original item from Files to the path recorded in
Restore-info.txt. App-specific album membership and references may not return.
There is no automatic expiry or copy/delete fallback. To remove data permanently,
open the Bin and choose **Empty Bin…**, or right-click selected bin items and choose
**Delete Permanently…**. Both require confirmation and cannot be undone. Empty Bin
removes validated recovery entries and leaves the Bin folder and ownership
marker ready for future use. Hidden contents inside selected payload folders are
included. Unrecognised top-level items are preserved.

Permanent deletion only accepts exact paths beneath verified Bin roots on the
selected storage. The root and its ownership marker cannot be deleted by it. Case-variant sibling paths are not treated as the bin. The
service removes children before parents; the backend rechecks each selection,
requires an empty directory before deleting it, and verifies disappearance.
No all-handles or format-wide wildcard is sent. On failure, the batch stops;
previous deletions cannot be undone and uncertain commands are never retried.
Definitive refused deletions preserve a usable session. A PartialDeletion
response remains uncertain and retires the session.
Keep these folders unchanged on the device while deletion runs: MTP cannot make
the empty-folder check atomic against concurrent changes from phone apps.

## Concurrency and failure boundaries

The UI excludes transfers/navigation during a bin batch. Backend operations are
serialized, and each move resolves both parents and checks the complete selected
metadata again. Destination conflict checks include hidden, case and canonical
name variants. After moving, the destination is checked and the original name
must be absent from the source. Move verification and recovery distinguish explicit refusals, unverified results
and lost sessions. A recoverable refusal retains browsing; an unsafe session is
retired. Failed operations are never replayed automatically.

Keep the affected folders unchanged in phone apps/file managers while a move
runs. Standard MTP provides no atomic create-if-absent move against concurrent
changes made on the device. A bin is also not a backup against storage failure,
formatting, firmware bugs, or manual removal. Malformed/unknown recovery records,
storage mismatches, extra payload items, and changed sizes/kinds stop Restore.

## Validation

Hardware-free tests cover full protocol-backed file/folder bin round trips,
fresh-session restoration, interrupted forward/reverse probes and original moves,
corrupted metadata readback, unsafe restore paths, destination conflicts,
missing parents, stale selections, unsupported operations, and browser state.
Wire tests check MoveObject parameters, root normalization, wildcard rejection,
malformed responses and absence of retries. Tests also cover scoped permanent
deletion, retained recovery notes after interruption, and rejection of stale or
foreign drag tokens. Finder drag promises are still fulfilled only on demand.

Tests also cover name collisions, failed initialisation, full-storage reuse
without writes, safe bulk deletion, and independent preparation for multiple
storages/devices. Physical validation follows the procedure below.

Start with a disposable file in a dedicated folder
on the phone; bin it, disconnect, inspect Files and Restore-info.txt in the phone's
file browser, reconnect and restore, then compare the downloaded contents.
Repeat with a disposable folder and on each separate storage. Test cameras only
with disposable content after confirming their folder/upload/move capabilities.
