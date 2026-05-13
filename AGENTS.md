# Repository Guidelines

## Project Structure & Module Organization
`Hyprtile` is a SwiftPM macOS 15+ menu bar app. Source lives in `Sources/Hyprtile/`.
- `HyprtileApp.swift`: app entry point and menu bar wiring
- `AppController.swift`: app state, permissions, window reconciliation
- `LayoutEngine.swift`: BSP layout logic
- `WindowController.swift`: Accessibility and window manipulation
- `InputRouter.swift`: mouse-driven move/resize input
- `PreferencesView.swift`, `AboutView.swift`: app UI

Packaging assets live in `Support/Hyprtile-Info.plist` and `scripts/package-macos-app.sh`. CI and release automation live in `.github/workflows/`. There is currently no `Tests/` directory.

## Build, Test, and Development Commands
- `swift build`: debug build for local development
- `swift run Hyprtile`: launch from SwiftPM for quick iteration
- `swift build -c release`: release build verification
- `scripts/package-macos-app.sh`: create `dist/Hyprtile.app` and a zipped release artifact

Use the packaged app when checking menu bar behavior, launch-at-login, permissions, or self-update flow.

## Coding Style & Naming Conventions
Use standard Swift style: 4-space indentation, `UpperCamelCase` for types, `lowerCamelCase` for properties/functions, and focused files with one main type per file when practical. Keep code ASCII unless the file already requires otherwise. Prefer explicit names such as `persistLayoutSnapshots()` over abbreviations.

No formatter or linter is configured yet. Match the surrounding style and keep comments brief and technical.

## Testing Guidelines
There is no automated test suite today. Before opening a PR, at minimum run:
- `swift build`
- `swift build -c release`
- `scripts/package-macos-app.sh`

Also do a short manual check on macOS: permission onboarding, tiling/monocle, drag/resize behavior, and menu items such as Preferences and Check for Updates. If you add tests, place them under `Tests/HyprtileTests/`.

## Commit & Pull Request Guidelines
Recent history is short and simple (`Initial commit`, `Initial Hyprtile v0.0.1`). Prefer concise, imperative commit subjects, for example: `Fix layout restore across Spaces`. Keep unrelated changes out of the same commit.

PRs should include a clear summary, verification steps, linked issues if any, and screenshots or short recordings for UI-visible changes.

## Security & Release Notes
Do not commit signing certificates, private keys, tokens, or provisioning files. Keep local signing identities in Keychain and CI secrets in GitHub settings. To ship a release, update `VERSION`; pushing `main` triggers the release workflow and uploads zip assets to GitHub Releases.
