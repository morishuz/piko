# Device drag and drop

Drag a selection onto a folder row, the Up button, or a storage entry in the
sidebar. A folder row targets that folder; Up targets the parent; a storage
entry targets its root. The device name/icon also targets the selected storage's root. Empty table space and ordinary
file rows target the displayed directory, including after hover navigation.
Hover over a folder, Up, device or storage for about 0.75 seconds to browse while
dragging. Device/storage hover opens root, even when already selected. The path
bar has clickable/drop-enabled ancestor segments: hover a parent name to open it,
then continue into another folder, or release to transfer there. Hovering Up pins
that parent until the pointer leaves, so releasing does not skip another level.
The hint identifies the destination and whether the operation is Move or Copy.

- **Same device and storage:** move using MTP MoveObject, without sending file
  contents through the Mac. This requires writable storage and MoveObject support.
- **Different storage or device:** copy through temporary files on the Mac.
  Originals remain on the source. The destination must support uploading; folder
  copies additionally require folder creation. Both devices must be connected.

Every destination storage must first have a recognised, prepared Bin. If Bin
preparation failed during connection, uploads and same-storage moves are blocked
there, including sidebar drops. It can still be the source of a copy to another
prepared storage. The gate is shared with the toolbar and context menus; ordinary
operation-specific refusals after successful preparation remain independent.

Existing names are skipped. An existing destination folder skips its entire
subtree; folders are not merged. Same-folder moves, self/descendant moves and
protected Bin paths are rejected. Use the Bin icon and restore controls for Bin
operations. A device may reject a write despite advertising support; a rejected
request does not automatically disable other folders or trigger a retry.

Both participating devices display progress and cancellation, and are reserved
until the batch finishes. Other devices remain independent. Copies first download
one file to private temporary storage, then upload it through the existing safe
snapshot and verification path. Peak temporary space is roughly twice the largest
file, not the whole selection. Temporary files are removed when the batch ends.

Cancel uses the device's supported safe boundary. Where active-file cancellation
is unavailable, Stop After Current File lets the current protocol operation finish.
Completed moves/copies remain completed; remaining items are not attempted. Original
files are never deleted by a copy. Refresh after cancellation to inspect completed
items. An uncertain destination write requires inspection and reconnection, and is
never automatically replayed or removed. A successfully cancelled partial upload is
removed only by the existing identity-checked cleanup path.

Drag selections retain their original device, storage and metadata while you browse.
A reconnect invalidates them. Drop acceptance reserves both device identities synchronously; UI updates and
backend work start after native drag handling returns. The transfer validates
source metadata again before moving or copying anything.

These controls are covered by synthetic transfer and native pasteboard tests.
Physical validation steps are in [Apple USB testing](TESTING.md).
