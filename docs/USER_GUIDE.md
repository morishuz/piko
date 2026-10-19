# Using Piko

Piko is preview software for **Apple Silicon and macOS 14 or newer**.

## Install and open

Download Piko from the [README download link](../README.md#download), unzip it,
then move **Piko.app** to your **Applications** folder.

Release downloads from version 0.16.0 are Developer ID signed and notarized by
Apple. Open the app normally; macOS may ask you to confirm opening an app
downloaded from the internet. No Gatekeeper override should be needed.

Older previews and development builds may be ad-hoc signed. See
[Apple's opening instructions](https://support.apple.com/en-us/102445) for those
builds. If a 0.16.0 or newer release reports a verification problem, download it
again from the official release rather than bypassing the warning.

Connect your device with a USB data cable, unlock it, and select **File Transfer**
if prompted. Close other apps using the device, then click **Connect** in Piko.
If connecting fails, follow the message in Piko, then click **Try Again**.
Connection problems do not open a separate pop-up.

## Before moving or deleting files

**Back up important files first.** Moving or deleting files that device software
depends on can break apps, damage their data, or prevent device features from
working. Permanent deletion can cause irreversible data loss. Only change files
you recognize; leave system and app-managed folders alone.

Try Piko with disposable copies first. The Bin is not a backup: moving a file
there removes it from its original location and can still disrupt software that
needs it. If an operation fails or its outcome is uncertain, stop making changes,
reconnect, and inspect both locations before trying again.

## The Bin

- **Move to Bin** keeps files on the same device storage, in a visible **Piko Bin**
  folder. It does not free space. Availability depends on device capabilities.
- Open the Bin, select an item, and choose **Restore…** to return it to its
  original location. Existing files are not overwritten; resolve any conflict
  before retrying.
- **Empty Bin…** and permanent deletion remove files from the device. Piko cannot
  undo this and never empties the Bin automatically. Unrecognized items are
  excluded from Empty Bin.

Keep the Bin's recovery files intact. If automatic restoration is unavailable,
each managed entry contains a `Restore-info.txt` note and a `Files` folder with
the recoverable item. Restored entries may retain empty recovery records.

## Diagnostics and privacy

Diagnostics are off until you enable them in Settings. Basic logs omit filenames,
paths, serial-number fields, and file contents. Detailed recording needs separate
consent and can include filenames, folder paths, and device details.

Logs stay on your Mac across restarts. Turning recording off stops new logs;
**Delete Diagnostics** removes retained logs. Delete exported copies separately.
Piko makes no internet connections and sends no reports automatically.

Review exports before sharing. Do not post private filenames, serial numbers,
unreviewed diagnostic exports, or Bin recovery files in public issues. For a bug
report, start with the Piko version, macOS version, device model, and steps using
disposable files.
