# Changelog

## Unreleased

### Added

- Keychain-backed credential storage with legacy migration from `UserDefaults`
- Reworked Settings UI for operating modes, providers, privacy, audio, and permissions diagnostics
- Release helper scripts for building, packaging, notarization, and verification
- README, security, contribution, architecture, privacy, permissions, threat model, and release docs
- GitHub issue templates, PR template, CI workflow, and draft release workflow
- Tests for microphone usage evaluation and system audio engine initialization

### Changed

- Audio capture is experimental and disabled by default
- Microphone capture now distinguishes external mic usage from the app's own input tap
- OCR, vision, and summary providers are configured from user-facing settings
- Data paths are centralized through `AppPaths`
- Default support matrix is documented as macOS 15+ on Apple Silicon

### Fixed

- Swift 6 concurrency errors in the app delegate pipeline
- Settings/API key tests leaking state across runs
- Package resource handling for the Whisper helper script
