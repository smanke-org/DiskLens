# DiskLens

**See what's filling your Mac's disk, and clean it up without breaking anything.**

When a Mac runs low on space, the hard part is finding out where the space went and what is
safe to remove. DiskLens scans a folder or drive in seconds, draws every file as a block
sized by the space it takes, and labels each item by how safe it is to delete. Files macOS
needs can't be selected for deletion at all. Everything DiskLens deletes goes to the Trash,
so you can put it back.

---

## ⬇️ Download

<p align="center">
  <a href="https://github.com/smanke-org/DiskLens/releases/latest/download/DiskLens.dmg">
    <img src="https://img.shields.io/badge/Download-DiskLens.dmg-2ea44f?style=for-the-badge&logo=apple&logoColor=white" alt="Download DiskLens.dmg" height="48">
  </a>
</p>

1. **[Download DiskLens.dmg](https://github.com/smanke-org/DiskLens/releases/latest/download/DiskLens.dmg)**
2. Open it and drag **DiskLens** to **Applications**.
3. Open DiskLens from Applications. It starts scanning your home folder right away.
4. For complete results, click **Open Privacy Settings** in the banner and turn on
   **Full Disk Access** for DiskLens. Without it, macOS hides folders such as Mail and
   Messages from every app, so their size isn't counted.

Requires macOS 26 or later. Signed with Developer ID and notarized by Apple.

---

## How it works

- **See it.** A treemap shows every file as a rectangle whose area matches its size, so the
  biggest space users stand out at once. Switch to a sunburst for a view by folder depth.
  Double-click to zoom into a folder; colors show file type or safety level.
- **Know what's safe.** Every item gets one of four labels, with the reason shown in the
  inspector:
  - **Safe to delete**: rebuilt or downloaded again when needed: caches, logs, Xcode build
    data, installers, things already in the Trash.
  - **Your files**: documents, downloads and media. Deleting them is your call.
  - **Use caution**: app data, settings, libraries (Photos, Music, Mail) and files inside
    app packages. DiskLens asks you to confirm that you understand before trashing these.
  - **Protected**: required by macOS or locked by it, plus standard folders such as
    Documents and Library themselves. These can't be added to the Trash list.
- **Delete safely.** Add items to the Trash list, review them, then move them to the Trash
  together. Cancel is always the default button, so a stray Return deletes nothing.

## Features

- **Largest Files** across a folder and all its subfolders, with app and document packages
  counted as one item.
- **Least Used** lists large files by when they were last opened, using Spotlight's record
  of each file being opened.
- **Cleanup Suggestions** collects the usual space users: app caches, logs, Xcode build
  data and device support files, old archives, simulators, iPhone backups, installers,
  old downloads and large files untouched for a year.
- **Duplicates** compares file contents (not just names) and shows how much you'd free by
  keeping one copy. APFS clones, copies that share storage, are marked, because deleting
  one frees nothing.
- **Filters** by name, type, size and how long since last use, applied to the lists and
  highlighted in the treemap.
- **Fast rescans.** DiskLens saves each scan and, when you come back, rescans only the
  folders macOS reports as changed.
- **Accurate totals.** Sizes are space actually used on disk: hard links count once,
  sparse files and iCloud files that aren't downloaded count as what they take locally.
- **Any folder or drive.** Add other folders or external drives to the sidebar.
- **URLs** for ToolHUD, Shortcuts or scripts: `disklens://open` brings DiskLens forward and
  `disklens://scan-home` scans your home folder.
- **Dock, menu bar, both or neither.** Choose in Settings. The menu bar item shows free
  space with one click. Right-click the Dock icon for **Settings…**.

## Updates

DiskLens checks GitHub for a new release once a day, or as often as you choose in Settings (a number of hours, days, weeks or months). In Settings
you choose what happens when it finds one:

- **Ask me first** (the default): a notification and *Update to …* in the sidebar; nothing
  installs until you click it.
- **Install automatically**: the update is downloaded and checked right away, then installed
  once no scan is running, nothing is waiting in the Trash list, no app is presenting or
  keeping the display awake, and the Mac hasn't been used for 2 minutes.
- **Don't check**: *Check for Updates…* in the DiskLens menu still works.

Before installing, DiskLens makes sure the download is signed by the same developer and
notarized by Apple. It updates the app in place, so Full Disk Access and your settings
carry over.

## Settings sync

Turn on *Sync settings with your other Macs* in Settings and where DiskLens appears, its
colors, chart style and cleanup threshold follow you to every Mac on the same iCloud
account, through `iCloud Drive/DiskLens/Settings.plist`. The folders you scan and your saved
scans stay on each Mac. A brand-new install that finds this file turns sync on and starts
from your settings.

## Building

```bash
./build_app.sh   # Developer ID signed app in .build/app
./install.sh     # copy to /Applications and launch
swift test       # unit tests for DiskLensKit
```

`./release.sh <version>` builds, notarizes, packages and publishes a GitHub release.
