# Hyprtile

[日本語版 README](./README_ja.md)

Hyprtile is a macOS 15+ menu bar tiling window manager built with SwiftUI and AppKit. The current version is `0.0.1`.

## v0.0.1 scope

- Menu bar only app
- Accessibility onboarding
- Display-local BSP tiling
- `Tiling`, `Pause`, and `Monocle` modes
- Normal drag-and-drop window repositioning
- Hold `Option` while dropping to force a top/bottom split
- Middle mouse drag to resize splits
- Launch at login registration

## Download

You can download packaged `.app` archives from GitHub Releases.

1. Open `https://github.com/igtm/hyprtile/releases/latest`
2. Choose the asset for your Mac
3. Unzip it and move `Hyprtile.app` into `Applications`
4. Launch it once and grant `Accessibility`

Release asset names:

- `Hyprtile_v0.0.1_aarch64-apple-darwin.zip`
- `Hyprtile_v0.0.1_x86_64-apple-darwin.zip`

## Development

```bash
swift build
swift run Hyprtile
```

Use a packaged app bundle when you need real menu bar distribution behavior and launch-at-login testing.

```bash
scripts/package-macos-app.sh
```

This writes `dist/Hyprtile.app` and `dist/Hyprtile_v0.0.1_<target>.zip`.

## Release Automation

GitHub Actions runs CI on pull requests and pushes to `main`. A push to `main`, including a merged pull request, also runs the release workflow.

The release workflow reads `VERSION`, creates or refreshes the `vX.Y.Z` GitHub Release, and uploads the following macOS app archives:

- `Hyprtile_vX.Y.Z_aarch64-apple-darwin.zip`
- `Hyprtile_vX.Y.Z_x86_64-apple-darwin.zip`

The same workflow also uploads the same zip files as GitHub Actions artifacts.

To publish a new release, update `VERSION` and the release workflow on the next push to `main` will publish `vX.Y.Z`.
