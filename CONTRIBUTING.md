# Contributing

## Development setup

```bash
make setup
swift build
swift test
```

If you do not need experimental audio, you can skip `make setup` and use plain `swift build` / `swift test`.

## Ground rules

- Keep defaults privacy-safe.
- Do not enable network providers or audio by default.
- Do not commit build artifacts, databases, captures, local models, or virtualenvs.
- Prefer small focused pull requests over broad mixed changes.

## Before opening a pull request

- run `swift build`
- run `swift test`
- update docs when behavior or settings change
- call out privacy or permission changes explicitly in the PR description

## Code style

- Follow the existing Swift style in the repo.
- Add comments only where they remove real ambiguity.
- Keep Settings and privacy changes user-facing; do not hide behavior behind undocumented defaults.

## Testing expectations

- Add or update tests for non-trivial logic changes.
- For OS-dependent code, prefer unit tests around decision logic and configuration boundaries.
- If a change cannot be fully automated, document the manual verification steps in the PR.
