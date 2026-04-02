# Memograph

Memograph is a local-first macOS activity memory tool. It watches the active app and window, captures screenshots for OCR when permissions allow it, builds a searchable timeline, generates summaries, and exports daily notes to Obsidian.

The public repository name is `Memograph`. The Swift package target is still named `MyMacAgent` internally for now, so that recent work can ship without a risky rename pass.

## Current status

- Public source repo: ready
- Public binary preview: in progress
- Stable 1.0: not ready

## What it does

- Tracks active apps and windows in a local SQLite database
- Captures screenshots adaptively when readability drops
- Extracts text with Accessibility, Vision OCR, or Ollama-based OCR
- Builds a daily timeline and search index
- Generates summaries locally or through an external LLM provider
- Exports daily notes to Obsidian
- Supports privacy rules, metadata-only apps, and a global pause switch

## Privacy model

- Data stays on your Mac by default.
- External model providers are optional and disabled until you configure them.
- Audio transcription is experimental and disabled by default.
- Screen capture, Accessibility, and microphone access are all optional.
- You can blacklist apps, blacklist window-title patterns, or mark apps as metadata-only.
- You can open the app data folder or delete all local data from Settings.

More detail: [privacy-model.md](docs/privacy-model.md)

## Support matrix

- macOS 15+
- Apple Silicon
- Source builds via SwiftPM
- Signed and notarized preview builds are still being prepared

## Permissions

- Screen Recording: enables screenshot capture and screenshot-based OCR
- Accessibility: improves app/window titles, focused UI context, selected text
- Microphone: optional, only used for experimental audio transcription

Permission degradation is explicit in the UI. If Screen Recording or Accessibility is denied, Memograph continues running in a reduced mode instead of failing.

More detail: [permissions.md](docs/permissions.md)

## Product modes

- `Local only`: network providers are ignored; summaries are local or disabled
- `Hybrid`: capture and OCR stay local; external summaries are allowed
- `Cloud-assisted`: external providers can be used for summaries and screenshot analysis

## Quick start

```bash
git clone https://github.com/MartinCampbell1/Memograph.git
cd Memograph
make setup
swift build
swift run MyMacAgent
```

`make setup` creates a Python virtualenv for experimental audio transcription and pulls the default local models from Ollama when it is installed.

## Configuration

Open Settings from the menu bar and configure:

- operating mode
- summary, vision, and OCR providers
- privacy rules and metadata-only apps
- retention and capture cadence
- Obsidian vault path
- external API key
- experimental audio runtime

## Data storage

By default, application data is stored under:

```text
~/Library/Application Support/MyMacAgent
```

That folder contains:

- `mymacagent.db`
- `captures/`
- `audio/`
- `system_audio/`

## Build and release

- CI runs `swift build` and `swift test` on every push and pull request.
- Release helper scripts live in `scripts/`.
- Draft release workflow lives in `.github/workflows/release.yml`.

More detail: [release-process.md](docs/release-process.md)

## Architecture

See [architecture.md](docs/architecture.md).

## Security

See [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
