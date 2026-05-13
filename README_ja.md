# Hyprtile

[English README](./README.md)

Hyprtile は SwiftUI と AppKit で実装した macOS 15+ 向けの menu bar tiling window manager です。現在のバージョンは `0.0.1` です。

## v0.0.1 scope

- menu bar 常駐アプリ
- Accessibility 権限の onboarding
- display ごとの BSP tiling
- `Tiling` / `Monocle` layout
- `Pause` / `Resume` state
- 通常ドラッグでの再配置
- `Option` を押しながら drop すると上下 split
- middle mouse drag による split resize
- launch at login 登録

## ダウンロード

GitHub Releases から配布済み `.app` zip をダウンロードできます。

1. `https://github.com/igtm/hyprtile/releases/latest` を開く
2. 使用する Mac に合わせて asset を選ぶ
3. zip を展開して `Hyprtile.app` を `Applications` へ移動する
4. 初回起動後に `Accessibility` を許可する

インストール後は menu bar の `About Hyprtile` と `Check for Updates...` から、現在の version 確認と GitHub Release からの app 内 update ができます。

release asset 名:

- `Hyprtile_v0.0.1_aarch64-apple-darwin.zip`
- `Hyprtile_v0.0.1_x86_64-apple-darwin.zip`

## 開発

```bash
swift build
swift run Hyprtile
```

menu bar 配布挙動と launch-at-login の確認には、packaged app bundle を使ってください。

```bash
scripts/package-macos-app.sh
```

生成物は `dist/Hyprtile.app` と `dist/Hyprtile_v0.0.1_<target>.zip` に出ます。

## リリース自動化

GitHub Actions は pull request と `main` への push で CI を実行します。pull request の merge も GitHub 上では `main` への push になるため、release workflow が実行されます。

release workflow は `VERSION` を読み取り、`vX.Y.Z` の GitHub Release を作成または更新し、以下の macOS app zip をアップロードします。

- `Hyprtile_vX.Y.Z_aarch64-apple-darwin.zip`
- `Hyprtile_vX.Y.Z_x86_64-apple-darwin.zip`

同じ workflow で GitHub Actions artifact にも同じ zip を残します。

新しい release を出す時は `VERSION` を更新してください。次の `main` への push で `vX.Y.Z` が publish されます。
