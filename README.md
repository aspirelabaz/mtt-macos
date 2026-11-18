# MTT — Android file transfer for macOS

Plug an Android phone into a Mac, choose **File transfer** on the phone, and
browse it like on Windows: in its own window, and in the **Finder sidebar**.

macOS has no built-in MTP support (Finder shows nothing, Image Capture only
reads photos). MTT talks MTP over USB with [libmtp](https://github.com/libmtp/libmtp)
and puts the phone in Finder through a File Provider extension.

## Features

- **Finder integration**: each phone storage appears under *Locations*; browse,
  open, copy in/out, create folders, rename, move, delete, with progress
  and cancel.
- **Browser window**: list and thumbnail grid, path bar, search, drag and drop
  both ways, copy/cut/paste, open with the default app, transfer queue.
- **Menu bar** item with phone name, battery and free space; runs at login.
- Handles plug/unplug, cancelled transfers (no stuck USB pipe), and macOS's
  `ptpcamerad` grabbing the phone (optional auto-release).
- `mtt` command-line tool: `detect`, `info`, `ls`, `pull`, `push`, `mkdir`,
  `rm`, `rename`, `watch`, `reset`.

Tested on macOS 27 with a Google Pixel 3 XL and a Samsung Galaxy S25 Edge.

## Layout

| Path | What |
|---|---|
| `Packages/MTPKit` | Swift wrapper around libmtp (`MTPKit`), the XPC protocol shared with the extension (`MTTShared`), and the `mtt` CLI |
| `App/` | SwiftUI app (XcodeGen project in `App/project.yml`); owns the USB connection and serves the extension over XPC |
| `FileProviderExt/` | Finder (File Provider) extension; sandboxed, talks to the app over XPC |
| `Vendor/libmtp` | libmtp 1.1.23 (patched, see `patches/`) and libusb 1.0.30 dylibs, LGPL-2.1 |
| `scripts/` | `install.sh`, `make-dmg.sh`, `build-libmtp.sh`, `make-icon.swift` |
| `PLAN.md` | Design notes and findings (Vietnamese) |

## Building

Requirements: Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and
an Apple ID signed in to Xcode (a free Personal Team works for your own Mac).

1. Set your team ID in `App/project.yml` (`DEVELOPMENT_TEAM`).
2. `scripts/install.sh` builds Release, installs to `/Applications/MTT.app`
   and starts it.
3. Allow MTT in **System Settings → General → Login Items & Extensions**
   (background item, and *File Providers → MTT*).

`scripts/make-dmg.sh` builds a drag-to-install DMG in `dist/`.

CLI only: `cd Packages/MTPKit && swift build && .build/debug/mtt info`
(quit the app first: only one process can hold the phone).

## License

MTT's own code is under the [MIT License](LICENSE).

The bundled libmtp and libusb (`Vendor/libmtp`) are LGPL-2.1 and keep that
license; they are linked dynamically, and their license texts are in
`Vendor/libmtp/licenses/`.
