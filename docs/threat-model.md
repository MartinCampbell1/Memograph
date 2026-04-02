# Threat Model

## Assets to protect

- screenshots
- OCR text
- summaries
- local SQLite database
- external provider credentials
- optional audio transcripts

## Primary threats

- accidental capture of sensitive apps or private windows
- credential leakage through settings or logs
- unexpected network use
- release artifacts that are unsigned or unverifiable
- retention failures that keep data longer than expected

## Current mitigations

- local-only mode
- Keychain-backed credentials
- blacklist and metadata-only rules
- global pause
- experimental audio off by default
- retention worker

## Residual risks

- signed/notarized preview distribution is not fully automated yet
- sensitive app defaults will need tuning from real-world usage
- system-audio behavior still needs additional manual soak testing on end-user machines
