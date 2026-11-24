# FileSync for iPhone / iPad (SwiftUI)

Same app as the Android version: pick two folders, compare, review, synchronise.
Written in Swift + SwiftUI, deployment target iOS 17, builds with the iOS 27 SDK (Xcode 27).

## Features
- Pick left / right folder with the Files folder picker (iCloud Drive, On My iPhone, USB drives, other providers); remembered between launches
- Compare by relative path, size and modified time (2 s tolerance)
- Modes: **Two-way ↔** (newer wins, deletions propagate, conflicts need a tap), **Mirror →** (right = exact copy of left), **Update →** (copy only, never delete)
- Preview list with per-file include/exclude
- Exclude filter (`*.tmp, .thumbnails, .DS_Store`)
- Confirmation before deleting, progress bar, result summary
- iOS-specific: copies keep the original modified time, existing files are replaced safely (temp file + swap), iCloud files are downloaded on demand

## Build (needs a Mac – Xcode only runs on macOS)
Xcode 27 requires an Apple-silicon Mac with macOS Tahoe 26.6 or newer.

**Option A – plain Xcode (most reliable)**
1. Xcode → File → New → Project → iOS → App. Name `FileSync`, Interface SwiftUI, Language Swift.
2. Delete the template's `ContentView.swift` and `FileSyncApp.swift`, then drag in the four files from `FileSync/` (FileSyncApp, ContentView, SyncViewModel, SyncEngine). Tick "Copy items if needed".
3. Target → Signing & Capabilities → pick your Apple ID as Team.
4. Plug in the iPhone (Settings → Privacy & Security → Developer Mode on), choose it as run target, press Run.

**Option B – XcodeGen**
`brew install xcodegen && xcodegen generate && open FileSync.xcodeproj`, then continue at step 3 above.

## No Mac?
Upload this folder to GitHub. `.github/workflows/build-ios.yml` builds an **unsigned IPA** on GitHub's Mac servers
(Actions → Build iOS app → download `FileSync-unsigned-ipa`). Unsigned means it cannot be installed as is:
sign and install it with a free Apple ID using a sideloading tool (for example AltStore or Sideloadly).

## Limits
- Free Apple ID: the app must be re-installed every 7 days. A paid developer account ($99/year) removes that and enables TestFlight.
- Only files are synchronised, not empty folders.
- iPadOS/iOS only lets apps touch folders you pick, so there is no whole-device access.
- Not compiled or tested yet (written without access to a Mac).
