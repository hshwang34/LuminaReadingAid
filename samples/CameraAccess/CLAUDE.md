# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CameraAccess is the main iOS app (bundle: `com.Lumina.ReadingAid`) for LuminaReading — a vocabulary learning app for international students reading English books. Users capture words/passages while reading, enrich them with dictionary lookups, and retain them through spaced repetition, all organized around a book library.

- **Platform**: iOS 18.0+, Swift, SwiftUI, MVVM (`@MainActor` ViewModels, `ObservableObject`)
- **Target**: App Store release as a standalone phone app

## Direction: Mobile-First, Voice-First (August 2026 pivot)

The app is pivoting away from Meta Ray-Ban glasses + hand-gesture capture to a phone-only, voice-first experience:

- **Voice is the primary input** — speak a word or sentence to capture/look it up; hear pronunciations and read-aloud via speech synthesis. Build on `SpeechService`, `WordConversationCoordinator`, and `OnDeviceLLMService`.
- **Phone camera OCR is a secondary capture path** (point at a page, tap a word) — no gestures, no glasses.
- **No hardware dependency** — the app must be fully functional on any iPhone.

### Legacy code slated for removal (do not extend)

- **Meta DAT SDK integration**: SPM dependency `meta-wearables-dat-ios` (`MWDATCore`, `MWDATCamera`, `MWDATMockDevice`), `WearablesViewModel`, `StreamSessionViewModel`, `StreamSessionView`/`StreamView`/`NonStreamView`, `RegistrationView` + Meta AI OAuth flow, `HEVCDecoder`, MockDeviceKit folders, MWDAT keys in `Info.plist` (`CLIENT_TOKEN`, `META_APP_ID`), `cameraaccess://` URL scheme, `bluetooth-peripheral`/`external-accessory` background modes.
- **Hand-gesture capture pipeline**: `HandPoseService`, `HandTrackingTypes`, `HighlightGestureTracker`, `HighlightGestureTypes`, `AnchorTrackingService`, `SelectionOverlayView`, `CameraMode` (collapses to phone camera only).
- **Perceptual hashing**: `PerceptualHash.swift`, `CoverTestHarness.swift`, `PerceptualHashTests` — pHash was already rejected in favor of OCR-text matching for book identification.

### Core to keep and evolve

- SwiftData models + `AppContainer.shared`
- `DefinitionService`, `SpacedRepetitionService`, `ReadingStatsService`, `WordNormalizer`
- `SpeechService`, `OnDeviceLLMService`, `WordConversationCoordinator` (voice-first foundation)
- `PhoneCameraService`, `WordCaptureService`, `PassageExtractionService` (secondary camera capture)
- `BookIdentification` services (cover scan / OCR-text matching to add books)
- Onboarding, RootTabView tabs (Library / Words / Practice / Profile), design system

## Architectural Constraints

- **On-device first, no server.** All core processing happens on the phone: Apple Vision, Speech, Core ML, on-device LLM. The only permitted external APIs are read-only metadata lookups: `dictionaryapi.dev` (definitions) and `openlibrary.org` / `covers.openlibrary.org` (book metadata + covers). No custom backend, no authenticated services, no write APIs. This is also the App Store privacy story: nothing leaves the device.

## Build & Test

**Claude must never run builds or tests (`xcodebuild`, simulators, etc.).** The user always builds and tests in Xcode themselves and reports results back. When a change needs verification, say what to build/run and what to look for.

## SwiftData Models

Five models managed by `AppContainer.shared` (`ModelContainer`):

- **`Book`** — title, author, cover image, reading state
- **`CapturedWord`** — vocabulary with definition/pronunciation/example, mastery level, review date, optional book link
- **`CapturedPassage`** — highlighted text with optional cropped image, optional book link
- **`ReadingSession`** — start/end times, page numbers, linked to a book
- **`QuizResult`** — quiz scores, type, words attempted

Relationships: Book → many CapturedWords, Book → many ReadingSessions (cascade delete), CapturedPassage → optional Book, QuizResult → many CapturedWords.

## Design System

`DesignSystem.swift` implements the "Pen & Paper" language documented in the repo-root `DESIGN_SYSTEM.md`:
- **Colors**: ink (deep brown), leather (sienna), amber (gold), parchment (cream bg), linen (card bg), brick (error), sage (success)
- **Typography**: serif fonts via `.serif()` for display/titles
- **Shadows**: `WarmShadow` enum (subtle, medium, cover) — always warm-tinted, never black
- **Spacing**: xs(4) through xxl(32)

## File Organization

Older services/models live at the root of `CameraAccess/` (e.g. `WordCaptureService`, `CapturedWord`, `CapturedPassage`); newer code is organized into `Services/`, `Models/`, `Views/`, `ViewModels/`. **The root-level copy is always the one in the Xcode target** — when both exist, edit the root-level file. Part of the refactor is consolidating everything into the subdirectories; Claude does this directly, moving the file and updating `project.pbxproj` (see Project File Ownership below).

### Known project-file issues

- `project.pbxproj` contains two file references to `SelectionOverlayView.swift` (both pointing at the root-level file, both in Sources). Claude should remove the duplicate when the legacy gesture code is deleted.

## Conventions

- Spaced repetition: mastery levels 0–5, intervals [1,2,4,7,14,30] days (`SpacedRepetitionService`).
- For any image/frame processing, prefer rejecting bad frames outright over smoothing/EMA (lag-free).
- Book identification uses OCR-text fuzzy matching against the library, with Open Library lookup on miss — never perceptual hashes.
- `#if DEBUG` gates all debug-only UI and test seed data (`Debug/TestWords.swift`).

## Planning Phase Behavior

When entering plan mode, be thorough before writing any plan:

- **Ask clarifying questions upfront** — scope, edge cases, expected behavior, priorities.
- **Challenge the approach** — raise more idiomatic Swift/SwiftUI patterns, simpler architectures, or better APIs proactively with reasoning.
- **Present trade-offs explicitly** with a clear recommendation.
- On re-entering plan mode, overwrite the plan file with only the new task — never append old plans.

## Implementation Phase: Project File Ownership

**Claude owns `project.pbxproj` and may edit it directly.** Do not stop and ask the user to click through Xcode for routine project changes — make the edit, validate it, and tell them what changed.

This covers: adding/removing files from targets, creating groups, build settings (including deployment target), `Info.plist` keys and background modes, entitlements files, build phases, schemes, SPM package references, and new targets (widget/app extensions).

### Required safety protocol

Every `project.pbxproj` edit must follow these steps. The format is unforgiving and a bad edit makes the project unopenable.

1. **Back up first**: `cp project.pbxproj project.pbxproj.backup-$(date +%Y%m%d-%H%M%S)` and tell the user the filename.
2. **Read before writing** — match the file's existing conventions. Note that this project is `objectVersion = 70` (Xcode 16) and *mixes two styles*:
   - `CameraAccessTests` is a `PBXFileSystemSynchronizedRootGroup`, so **files added under `CameraAccessTests/` need no project edit at all** — they are compiled automatically. Its `PBXSourcesBuildPhase` is intentionally empty; do not add entries to it.
   - The `CameraAccess` app target uses explicit refs. A new file needs four entries: `PBXFileReference`, `PBXBuildFile`, membership in a `PBXGroup`, and an entry in the app's `PBXSourcesBuildPhase` (id `AAAAAAAAAAAAAAAAAAAAAA`).
   - A `Services/` subdirectory becomes a `PBXGroup` with `name = X; path = Services/X;` parented to the main `CameraAccess` group (id `8FD96B7D2E6F0A9800F56AB1`) — follow the `BookIdentification` precedent.
3. **Use a script, not hand-editing** — generate unique 24-hex-char object IDs and assert they don't already exist in the file.
4. **Validate afterwards**, always:
   - `plutil -lint project.pbxproj` (pbxproj is an old-style ASCII plist; `plutil` reads it, Python's `plistlib` does not)
   - `plutil -convert xml1 -o /tmp/pbx.xml project.pbxproj`, then parse with `plistlib` and assert: every new file resolves into the intended target's sources phase, every new group is parented, and every referenced source path exists on disk.

### Still requires the user

Only these — ask, don't attempt:

- **Apple Developer portal actions**: App Group creation, Push/iCloud capability provisioning, signing certificates and profiles.
- **SPM package resolution**: a package reference can be written into the project, but Xcode must fetch and resolve it on next open. Say so, and expect a resolution step before the build works.
- **Anything requiring a build to verify** — see Build & Test above; Claude never runs `xcodebuild`.
