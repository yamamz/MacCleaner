# MacSweep

A native SwiftUI Mac cleaner inspired by CleanMyMac. Requires macOS 14 Sonoma or later.

<img src="Resources/AppIcon-preview.png" width="128" alt="MacSweep icon">

## Install
With [Homebrew](https://brew.sh):
```bash
brew install --cask yamamz/tap/macsweep
```
Update with `brew upgrade --cask macsweep`.

Or download the latest `MacSweep-x.y.z.zip` from [Releases](https://github.com/yamamz/MacCleaner/releases),
unzip it and move **MacSweep.app** to Applications.

MacSweep isn't signed with an Apple Developer ID, so macOS blocks it the first time:
1. Double-click MacSweep, then click **Done** on the warning.
2. Open **System Settings › Privacy & Security**, scroll down and click **Open Anyway** next to the message about MacSweep.
3. Open MacSweep again and confirm with **Open Anyway**.

On macOS 15 and later, Control-click › Open no longer gets past the warning. Alternatively, run
`xattr -dr com.apple.quarantine /Applications/MacSweep.app`.

For full results, add MacSweep in **System Settings › Privacy & Security › Full Disk Access**
(needed for the Trash, Mail and app containers), then quit and reopen it.

## Features
### Cleanup
- **Smart Scan** – one click scans junk, Trash, large files and free storage, then cleans.
- **System Junk** – user caches, logs, Xcode DerivedData / DeviceSupport / simulator caches,
  dev package caches (npm, Yarn, pnpm, Gradle, pip, CocoaPods, Maven), Mail attachments,
  leftover installers (.dmg/.pkg) in Downloads, old Xcode archives.
- **Simulators** – Xcode simulator runtimes and devices with their sizes (these make up much of
  macOS's "System Data"). Delete a whole runtime with its devices or pick single devices;
  **Keep Newest Only** selects every runtime except the newest per platform. Uses `xcrun simctl`.
- **Android Emulators** – emulators in `~/.android/avd` and system images in the Android SDK.
  Delete an emulator, only its quick-boot snapshots, or wipe its data (like Android Studio's Wipe Data);
  remove system images no emulator uses. Honours `ANDROID_AVD_HOME`, `ANDROID_USER_HOME`,
  `ANDROID_HOME` and `ANDROID_SDK_ROOT`.
- **Large & Old Files** – finds files over 50 MB in your home folder, filterable by size and last-opened date.
- **Duplicates** – finds identical files (size → 64 KB hash → full SHA-256), ignores hard links,
  keeps the oldest copy and can never remove every copy of a file.
- **Trash Bins** – shows the Trash size and empties it.

### Protection
- **Malware & Bloatware** – local checks only, nothing is sent anywhere:
  - known macOS adware families and potentially unwanted "optimizer" apps,
    matched in apps, launch agents and browser extensions;
  - suspicious launch agents/daemons: pretending to be Apple, downloading code with `curl`,
    running encoded commands, running from temporary or hidden folders, or with a broken signature;
  - apps whose code signature is broken;
  - Chrome/Brave/Edge/Vivaldi/Arc extensions and browser policies that take over search or homepage;
  - apps not used in 6+ months (Spotlight's last-opened date, or the app's own preferences and data).

  These are heuristics, not a full antivirus. The screen also shows your XProtect version.

### Storage
- **Space Lens** – drill down folder by folder to see what's using your disk, with size bars.
  Results stream in as each folder is measured, the work runs on all cores
  (`getattrlistbulk`, about as fast as `du`), and opening a subfolder after the first scan is instant.

### Applications
- **Uninstaller** – removes apps plus their leftovers in ~/Library (Application Support, Caches,
  Preferences, Containers, Saved State, LaunchAgents…). Apple apps are excluded. Apps owned by root
  (App Store, installers) are moved to the Trash by Finder, which asks for your password.
- **Optimization** – review/remove your Launch Agents; view system agents & daemons; jump to Login Items.

### Performance
- **Maintenance** – flush DNS, free up RAM, reindex Spotlight, rebuild Launch Services, reset Quick Look,
  clear font caches, relaunch Finder & Dock. Admin tasks use the standard macOS password prompt.
- **Monitor** – live CPU, memory and storage gauges, CPU history, running apps by memory with Quit.
- **Menu bar monitor** – live CPU % in the menu bar with a CPU/memory/storage popover (toggle in Settings).

### Settings
- **Ignore List** – folders/files (Settings › Ignore List) that are never scanned or cleaned.

## Safety
- Everything is **moved to the Trash** by default (recoverable). Permanent delete is an opt-in in Settings (⌘,).
  The exception is **Simulators**: `simctl` deletes them permanently, which the screen says up front.
- A protected-path guard refuses to remove anything outside your home folder (except `.app` bundles)
  and never removes key folders like `~/Library/Caches` itself — only their contents.
- Running simulators and emulators can't be selected, and nothing is selected by default on the
  Simulators, Android Emulators and Malware & Bloatware screens.
- Every clean asks for confirmation.

## Build & run
```bash
./build-app.sh            # creates build/MacSweep.app and build/MacSweep-<version>.zip
open build/MacSweep.app
```
For development: `swift run`. Run the tests with `swift test`.

### Code signing and Full Disk Access
macOS ties a Full Disk Access grant to the app's code signature. An ad-hoc signature changes on every
build, which silently invalidates the grant. `build-app.sh` therefore signs with a code-signing identity
named **MacSweep Local** if one is in your keychain, and falls back to ad-hoc signing otherwise.
Set `MACSWEEP_SIGN_IDENTITY` to use a different identity.

If Full Disk Access shows as on but MacSweep still can't read the Trash, the stored grant belongs to an
older signature. Reset it, then add MacSweep again in System Settings:
```bash
tccutil reset SystemPolicyAllFiles com.macsweep.app
```

### App icon
The icon is drawn in code. To regenerate `Resources/AppIcon.icns`, run:
```bash
swift scripts/make-icon.swift
```

### Releasing
1. Set `VERSION` in `build-app.sh` (the build number is the git commit count).
2. Commit, then run `./build-app.sh` to produce `build/MacSweep-<version>.zip`.
3. Tag and publish:
   ```bash
   git tag -a v1.0.1 -m "MacSweep 1.0.1" && git push origin main v1.0.1
   gh release create v1.0.1 build/MacSweep-1.0.1.zip --title "MacSweep 1.0.1" --notes-file notes.md
   ```
4. Homebrew: [yamamz/homebrew-tap](https://github.com/yamamz/homebrew-tap) checks for new releases daily
   and opens a pull request that bumps the cask; merge it. To bump right away instead:
   ```bash
   brew bump-cask-pr --version 1.0.1 yamamz/tap/macsweep
   ```

## Tests
`swift test` runs 102 XCTest cases against throwaway temp folders and sample data (never your real files),
covering the safety guard (protected folders, symlink escapes, `..` traversal), every scanner, disk-usage
measurement and caching, duplicate detection, leftover matching, launch-agent parsing, simulator and
emulator detection and the commands used to delete them, the malware and bloatware heuristics,
code-signature checks, CPU math and maintenance command building.
