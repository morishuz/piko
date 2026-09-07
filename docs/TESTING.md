# Testing Piko

## Install the preview

Requires Apple Silicon and macOS 14+. Extract the archive and open Piko.app.
The preview is ad-hoc signed, not notarized. Only approve opening a build you trust
through macOS Privacy & Security. Close other apps using the same device.

## Physical-device checks

Use disposable files in a dedicated test folder. Record the app version/build,
macOS version, device model/firmware, cable/hub setup, operation, and result.
Automated tests simulate devices; they do not establish hardware compatibility.

1. Connect by USB, unlock the device, select file-transfer mode if needed, then
   choose Connect in Piko. Confirm storage and nested folders load.
2. Download a known file and folder, including an empty folder. Compare SHA-256
   hashes against the originals. Test dragging the same selection to Finder.
3. On writable storage, upload disposable files/folders, download them again,
   and compare hashes. Confirm name conflicts preserve existing items.
4. Cancel a larger transfer and then browse/download on the same connection.
   If the device offers Stop After Current File, wait for that file to finish.
   Inspect the destination after an error or uncertain cleanup before retrying.
5. Move a disposable item to Piko Bin. Disconnect and inspect its Files folder
   and Restore-info.txt on the device. Reconnect, restore, and compare contents.
   Test permanent deletion only on disposable bin contents.
6. Test disconnect/reconnect, several connected devices, and a safe quit during
   a transfer. Confirm stale selections cannot affect a new session.

For repeatable data, `PikoTools generate <directory>` creates an integrity kit;
`PikoTools verify <directory>/MTP-Synthetic` verifies it after a round trip.
Run `PikoTools --help` for the available commands. Keep generated kits out of Git.

## Diagnostics

Recording is off by default. If needed, enable it in Settings before reproducing
an issue. Enable filename details only if needed, export promptly, review the
report before sharing, and turn recording off afterward. Reports are saved
locally and never sent by Piko. See [diagnostics](DIAGNOSTICS.md).

For automated checks and package verification, see [contributing](../CONTRIBUTING.md).
