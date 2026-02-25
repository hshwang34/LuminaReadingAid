# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

CameraAccess is an iOS sample app (bundle: `com.Lumina.ReadingAid`) demonstrating the Meta Wearables Device Access Toolkit (DAT) SDK. It streams live video from Meta Ray-Ban smart glasses, captures photos, and manages device connection states.

- **Platform**: iOS 17.0+, Swift 5.0, SwiftUI
- **Dependency**: `meta-wearables-dat-ios` v0.4.0 via Swift Package Manager
- **SDK modules used**: `MWDATCore`, `MWDATCamera`, `MWDATMockDevice` (DEBUG only)

## Build & Test Commands

```bash
# Build (requires Xcode, resolves SPM packages automatically)
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run tests (uses MockDeviceKit — no physical device needed)
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' test

# Run a single test
xcodebuild -project CameraAccess.xcodeproj -scheme CameraAccess -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CameraAccessTests/ViewModelIntegrationTests/testVideoStreamingFlow test
```

## Architecture

MVVM with SwiftUI. All ViewModels are `@MainActor` and use `ObservableObject`.

**App entry flow**: `CameraAccessApp` → configures `Wearables.shared` singleton → `MainAppView` switches between:
- `HomeScreenView` → registration/onboarding (when unregistered)
- `StreamSessionView` → `StreamView` (active stream) or `NonStreamView` (pre-stream)

**Key patterns**:
- DAT SDK uses a listener/token pattern for event subscriptions (`statePublisher.listen`, `videoFramePublisher.listen`). Tokens must be retained.
- `AutoDeviceSelector` handles device selection from the SDK.
- `StreamSession` is the core streaming object — configured with codec, resolution, frame rate.
- `#if DEBUG` blocks gate all `MWDATMockDevice` imports and debug UI (mock device panel, debug menu overlay).

**Folder structure** (all source under `CameraAccess/`):

```
CameraAccess/
├── CameraAccessApp.swift          # App entry point
├── CapturedWord.swift             # SwiftData model + AppContainer.shared
├── HandPoseService.swift          # Hand pose detection (MCP-anchored formula)
├── HandTrackingTypes.swift        # HandTrackingConfig thresholds & types
├── WordCaptureService.swift       # OCR via VNRecognizeTextRequest on fingertip crop
├── ViewModels/
│   ├── WearablesViewModel.swift
│   ├── StreamSessionViewModel.swift
│   ├── DebugMenuViewModel.swift
│   └── MockDeviceKit/
│       ├── MockDeviceKitViewModel.swift
│       └── MockDeviceViewModel.swift
└── Views/
    ├── MainAppView.swift
    ├── HomeScreenView.swift
    ├── RegistrationView.swift
    ├── StreamSessionView.swift
    ├── StreamView.swift
    ├── NonStreamView.swift
    ├── PhotoPreviewView.swift
    ├── DebugMenuView.swift
    ├── Components/
    │   ├── CardView.swift
    │   ├── CircleButton.swift
    │   ├── CustomButton.swift
    │   ├── HandOverlayView.swift  # Visualizes hand joints & pointing gesture
    │   ├── MediaPickerView.swift
    │   └── StatusText.swift
    └── MockDeviceKit/             # DEBUG only
        ├── MockDeviceCardView.swift
        ├── MockDeviceKitButton.swift
        └── MockDeviceKitView.swift
```

**Root-level file note**: `HandPoseService.swift`, `HandTrackingTypes.swift`, `WordCaptureService.swift`, and `CapturedWord.swift` live at the root of `CameraAccess/` (not in a `Services/` or `Models/` subfolder). Always edit these root-level copies.

**ViewModels**:
- `WearablesViewModel` — registration state, device list, compatibility monitoring
- `StreamSessionViewModel` — streaming lifecycle, video frames (`UIImage`), photo capture
- `DebugMenuViewModel` / `MockDeviceKitViewModel` — DEBUG-only mock device simulation

**Services** (root-level, no subdirectory):
- `HandPoseService` — detects index-extended / middle-curled gesture from Vision hand observations
- `WordCaptureService` — runs `VNRecognizeTextRequest` on a crop region above the index fingertip; returns recognized word + cropped `UIImage`
- `CapturedWord` — SwiftData `@Model` for persisted captured words; `AppContainer.shared` provides the `ModelContainer`

## SDK Configuration

`Info.plist` contains MWDAT config block with build-variable references (`CLIENT_TOKEN`, `META_APP_ID`, `DEVELOPMENT_TEAM`). URL scheme: `cameraaccess://`. Background modes: `bluetooth-peripheral`, `external-accessory`. External accessory protocol: `com.meta.ar.wearable`.

## Planning Phase Behavior

When entering plan mode, be thorough and inquisitive before writing any plan:

- **Ask many clarifying questions upfront.** Do not assume requirements — ask about scope, edge cases, expected behavior, target users, constraints, and priorities. More questions early means fewer rewrites later.
- **Challenge the approach.** If there is a better alternative to what was requested — a more idiomatic Swift/SwiftUI pattern, a simpler architecture, a more performant API, or a more maintainable design — raise it proactively. Explain *what* the alternative is, *why* it's better, and *why the user should lean toward it*. Do not silently go along with a suboptimal path.
- **Present trade-offs explicitly.** When multiple valid approaches exist, lay out the pros/cons of each and give a clear recommendation with reasoning.
- **Question before committing.** Never finalize a plan without confirming the user is aligned on the direction. It's better to over-ask than to build the wrong thing.

## Implementation Phase: Xcode Delegation

When an implementation step requires Xcode GUI actions that are error-prone or impossible to do reliably from the CLI — **stop immediately and ask the user to do it manually in Xcode.** Do not attempt to brute-force `.pbxproj` edits or simulate Xcode-only workflows from the terminal.

Common cases to delegate:
- Adding/removing SPM package dependencies
- Changing build settings (signing, capabilities, entitlements)
- Adding frameworks to "Link Binary With Libraries"
- Modifying build phases or run scripts
- Changing scheme settings or test plans
- Adding new targets or extensions
- Configuring background modes or app capabilities
- Resolving Xcode-specific build errors tied to project settings

Format the delegation as: a clear numbered step list of exactly what to click/change in Xcode, then confirm when done so implementation can resume.

## Meta DAT SDK Reference (v0.4.0)

Key types for Vision integration:
- `VideoFrame.sampleBuffer` — raw `CMSampleBuffer` (added v0.2.1). Use `CMSampleBufferGetImageBuffer()` to get `CVPixelBuffer` for zero-copy Vision framework input.
- `VideoFrame.makeUIImage()` — convenience UIImage conversion (returns nil when backgrounded/HEVC).
- Foreground frame format: `420v` (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange). Background: HEVC compressed.
- `StreamingResolution`: `.low`, `.medium` (504x896), `.high` (up to 720p).
- Valid frame rates: 2, 7, 15, 24, 30. SDK has adaptive bitrate that may step down.
- No IMU/head tracking/sensor data available — camera and photo capture only.

## Testing

Tests use `MWDATMockDevice` to simulate device pairing and camera feeds. Test assets (`plant.png`, `plant.mp4`) are in `CameraAccessTests/Assets/`. Tests involve real async waits (`Task.sleep`) for SDK event propagation — expect 10+ second test durations.
