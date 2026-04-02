# Release Process

## Goals

- reproducible source build
- draft-first GitHub release flow
- room for later codesign and notarization

## Local flow

```bash
swift test
./scripts/build_release.sh
./scripts/package_dmg.sh
./scripts/verify_release.sh
```

For notarization:

```bash
NOTARY_PROFILE=your-profile ./scripts/notarize.sh
```

## GitHub flow

- `ci.yml` runs on pushes and pull requests
- `release.yml` runs on tags matching `v*`
- release artifacts are uploaded to a draft GitHub Release

## Before publishing a binary preview

- confirm privacy-safe defaults
- verify permissions degradation behavior
- verify retention and data paths
- run `swift test`
- run a short manual smoke test on a clean machine
