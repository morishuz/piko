# Piko

Fast, fully native macOS file transfers for Android phones, cameras, and other
USB MTP devices. Drag and drop files, free up space, and manage several devices
from one window.

![Piko browsing an Android phone with a camera connected](images/piki-screenshot.png)

**Apple Silicon · macOS 14 or newer**

## What you can do

- **Drag and drop** files and folders between your Mac and connected devices.
- **Organize files** by moving them between folders on the same storage.
- **Transfer between devices** by dragging to another device or storage. Files
  are copied, keeping the originals safe.
- **Free up space** with file deletion, a recoverable bin, and permanent deletion
  when you're ready.
- **Browse photos and videos** with thumbnail previews in a list or image grid.
- **Work with several devices** at once, each with its own transfers.

Available actions depend on your device. Existing files are never overwritten.

## Download

Preview builds are available through this repository's **Actions** tab:

1. Open the latest successful **CI** run with a **Piko** artifact.
2. Under **Artifacts**, download `Piko-…-arm64`.
3. Extract the download, then the Piko ZIP inside it, and open **Piko.app**.

You must be signed into GitHub. While the repository is private, you also need
access to it. Builds expire after 30 days. If no Piko artifact is listed, a
preview download is not available yet.

Previews are not yet notarized by Apple. macOS may require you to approve opening
Piko in **System Settings → Privacy & Security**.

## Getting started

Connect your device with a USB data cable, unlock it, and choose **File Transfer**
on the device if prompted. Click **Connect** in Piko, then start browsing or dragging
files. Close other apps that are using the same device.

## Private by default

Piko makes **no internet connections** and records **no diagnostic logs** unless
you explicitly enable them in Settings. Logs stay on your Mac; including filenames
requires separate consent. You choose whether to export, share, or delete them.

## More

[Build from source](CONTRIBUTING.md) · [Device bin](docs/DEVICE_BIN.md) ·
[Diagnostics](docs/DIAGNOSTICS.md) · [MIT license](LICENSE) ·
[Third-party acknowledgments](THIRD_PARTY_NOTICES.md) · [Security](SECURITY.md)
