# Architecture

## High-level flow

```text
AppMonitor / WindowMonitor / IdleDetector
        |
        v
SessionManager
        |
        +--> CaptureScheduler / CapturePolicyEngine
        |         |
        |         v
        |   ScreenCaptureEngine
        |         |
        |         +--> AccessibilityContextEngine
        |         +--> OCRPipeline
        |         +--> VisionAnalyzer (for low-readability fallback)
        |
        v
ContextFusionEngine
        |
        v
SQLite (DatabaseManager + migrations)
        |
        +--> TimelineDataProvider / SearchEngine
        +--> DailySummarizer / LLMClient
        +--> ObsidianExporter
        +--> RetentionWorker
```

## Core modules

- `Monitors/`: foreground app, window title, idle tracking
- `Session/`: session boundaries and event recording
- `Capture/`: screenshot capture, image preprocessing, capture persistence
- `Accessibility/`: contextual text from AX APIs
- `OCR/`: provider abstraction, fallback OCR chain, normalization, persistence
- `Fusion/`: merged context snapshots with readability and uncertainty scores
- `Summary/`: daily prompt construction and summary generation
- `Audio/`: experimental microphone and system-audio transcription
- `Privacy/`: blacklist, metadata-only, and pause decisions
- `Views/` and `Settings/`: timeline UI, summary UI, settings UI, menu bar controls

## Storage

- SQLite is the source of truth.
- Capture files and audio segments live alongside the database in the app data directory.
- Retention is enforced via the `RetentionWorker`.

## Runtime configuration

- `AppSettings` controls operating mode, providers, privacy defaults, audio, and storage paths.
- Credentials are stored in Keychain through `CredentialsStore`.
- `AppPaths` resolves the current data locations.
