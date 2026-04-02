# Permissions

## Screen Recording

Used for:

- screenshot capture
- screenshot-based OCR
- screenshot-based vision analysis

If denied:

- screenshot capture is skipped
- app/window monitoring still works
- summaries rely on non-visual context only

## Accessibility

Used for:

- window titles
- focused UI context
- selected text

If denied:

- OCR can still run on screenshots
- window metadata may be reduced
- focused element context is unavailable

## Microphone

Used for:

- experimental microphone transcription

If denied:

- microphone capture stays off
- the rest of the app continues normally

## UX principles

- Memograph should never look broken when a permission is denied.
- The UI should explain what is missing and what still works.
- Permission prompts are opt-in and tied to the relevant feature.
