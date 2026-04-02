# Privacy Model

## Defaults

- Local storage first
- External providers disabled until configured
- Audio disabled by default
- Global pause available from the menu bar

## Data categories

- app/window metadata
- screenshots
- OCR text
- fused context snapshots
- summaries
- optional audio transcripts

## Sensitive app handling

- Some apps are blacklisted by default.
- Some apps are metadata-only by default.
- Window-title pattern blocking prevents obvious private/incognito/password contexts from being captured.

## External providers

- External summaries and vision analysis only run when the user explicitly configures them.
- Credentials are stored in Keychain.
- Local-only mode disables external provider use at runtime even if fields are filled in.

## Local data deletion

- The Settings window can request deletion of all local data.
- Data lives under the configured app data directory.
- Exported notes in Obsidian are not deleted automatically.
