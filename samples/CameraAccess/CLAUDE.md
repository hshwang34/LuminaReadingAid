# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CameraAccess is the main iOS app (bundle: `com.Lumina.ReadingAid`) for LuminaReading — a vocabulary learning app for international students reading English books. Users capture words/passages while reading, enrich them with dictionary lookups, and retain them through spaced repetition, all organized around a book library.

- **Platform**: iOS 17.0+, Swift, SwiftUI, MVVM (`@MainActor` ViewModels, `ObservableObject`)
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

Older services/models live at the root of `CameraAccess/` (e.g. `WordCaptureService`, `CapturedWord`, `CapturedPassage`); newer code is organized into `Services/`, `Models/`, `Views/`, `ViewModels/`. **The root-level copy is always the one in the Xcode target** — when both exist, edit the root-level file. Part of the refactor is consolidating everything into the subdirectories (via Xcode, not pbxproj edits).

### Known project-file issues (fix in Xcode, flag to user)

- `project.pbxproj` contains two file references to `SelectionOverlayView.swift` (both pointing at the root-level file, both in Sources). Remove the duplicate when the legacy gesture code is deleted.

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

## Implementation Phase: Xcode Delegation

When an implementation step requires Xcode GUI actions — **stop and ask the user to do it manually.** Do not brute-force `.pbxproj` edits.

Delegate: adding/removing files from targets, SPM dependencies, build settings, signing/capabilities, frameworks, build phases, schemes, new targets, background modes.
