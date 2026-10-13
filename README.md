# MacSweep

A native SwiftUI Mac cleaner inspired by CleanMyMac.

## Features
- **Smart Scan** – one click scans junk, Trash, large files and free storage, then cleans.
- **System Junk** – user caches, logs, Xcode DerivedData / DeviceSupport / simulator caches,
  dev package caches (npm, Yarn, pnpm, Gradle, pip, CocoaPods, Maven), Mail attachments,
  leftover installers (.dmg/.pkg) in Downloads, old Xcode archives.
- **Large & Old Files** – finds files over 50 MB in your home folder, filterable by size and last-opened date.
- **Duplicates** – finds identical files (size → 64 KB hash → full SHA-256), ignores hard links,
  keeps the oldest copy and can never remove every copy of a file.
- **Space Lens** – drill down folder by folder to see what's using your disk, with size bars.
- **Trash Bins** – shows Trash size and empties it.
- **Uninstaller** – removes apps plus their leftovers in ~/Library (Application Support, Caches,
  Preferences, Containers, Saved State, LaunchAgents…). Apple apps are excluded.
- **Optimization** – review/remove your Launch Agents; view system agents & daemons; jump to Login Items.
- **Maintenance** – flush DNS, free up RAM, reindex Spotlight, rebuild Launch Services, reset Quick Look,
  clear font caches, relaunch Finder & Dock. Admin tasks use the standard macOS password prompt.
- **Menu bar monitor** – live CPU % in the menu bar with a CPU/memory/storage popover (toggle in Settings).
- **Ignore List** – folders/files (Settings › Ignore List) that are never scanned or cleaned.
- **Monitor** – live CPU, memory and storage gauges, CPU history, running apps by memory with Quit.

## Safety
- Everything is **moved to the Trash** by default (recoverable). Permanent delete is an opt-in in Settings (⌘,).
- A protected-path guard refuses to remove anything outside your home folder (except `.app` bundles)
  and never removes key folders like `~/Library/Caches` itself — only their contents.
- Every clean asks for confirmation.

## Build & run
```bash
./build-app.sh            # creates build/MacSweep.app
open build/MacSweep.app
```
For development: `swift run`. Run the tests with `swift test`.

For full results, grant Full Disk Access in System Settings › Privacy & Security
(needed for Trash, Mail and app containers).

## Tests
`swift test` runs 74 XCTest cases against throwaway temp folders (never your real files), covering the
safety guard (protected folders, symlink escapes, `..` traversal), every scanner, duplicate detection,
leftover matching, launch-agent parsing, CPU math and maintenance command building.
