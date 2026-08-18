# Anton — releases

Public download host for [Anton](https://github.com/saadhu-xyz/anton), a personal
developer-productivity platform driven from a Flutter app.

**This repo contains no source code.** It exists so the downloads on the Anton site
resolve for anyone, without making the application repository public. Everything
ships as **release assets** — nothing binary is committed to git, so cloning this
repo stays instant no matter how many builds accumulate.

## Downloads

Always-current links (they follow whatever the newest release is):

| Platform | Link |
|---|---|
| Android | [`anton.apk`](https://github.com/saadhu-xyz/anton-releases/releases/latest/download/anton.apk) |
| macOS · Apple Silicon | [`Anton-arm64.dmg`](https://github.com/saadhu-xyz/anton-releases/releases/latest/download/Anton-arm64.dmg) |
| macOS · Intel | [`Anton-x86_64.dmg`](https://github.com/saadhu-xyz/anton-releases/releases/latest/download/Anton-x86_64.dmg) |
| Linux · x86-64 | [`anton-linux-amd64.tar.gz`](https://github.com/saadhu-xyz/anton-releases/releases/latest/download/anton-linux-amd64.tar.gz) |
| Linux · ARM64 | [`anton-linux-arm64.tar.gz`](https://github.com/saadhu-xyz/anton-releases/releases/latest/download/anton-linux-arm64.tar.gz) |

To pin a specific version, swap `latest/download` for `download/<tag>` — e.g.
`.../releases/download/v1.0.0/anton.apk`.

Every release ships a `SHA256SUMS` asset. Verify before installing:

```sh
curl -LO https://github.com/saadhu-xyz/anton-releases/releases/latest/download/anton.apk
curl -LO https://github.com/saadhu-xyz/anton-releases/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

## Installing

### Android

Sideload the APK. You'll need "install unknown apps" enabled for whichever app
opens the download.

### macOS

The DMGs are **unsigned** — there's no Apple Developer signature or notarization.
On a Mac that didn't build it, Gatekeeper blocks first launch, usually with the
misleading **"Anton is damaged and can't be opened"** on Apple Silicon. Nothing is
damaged.

Open the DMG and double-click `Install Anton.command`, which handles it. Or do it
by hand:

```sh
xattr -cr /Applications/Anton.app
codesign --force --deep --sign - /Applications/Anton.app
open /Applications/Anton.app
```

The quarantine flag that triggers this is attached by browsers, Mail, Messages and
AirDrop — so copying the app between Macs is exactly when it bites. Transfer via
`scp`, `rsync`, `curl` or a USB drive copied in Terminal and no flag is set.

Match the DMG to your chip: `uname -m` → `arm64` or `x86_64`.

### Linux

Extract the tarball and install the three binaries:

```sh
tar xzf anton-linux-amd64.tar.gz
sudo install anton anton-ticketing anton-impl-server /usr/local/bin/
```

## Publishing a release

From a checkout of this repo, pass each artifact behind the flag for its
platform. The flag decides the published filename, so build output can be handed
over under whatever name the toolchain produced:

```sh
./scripts/publish-release.sh v1.0.1 \
  --android     ../anton/mobile/build/app/outputs/flutter-apk/app-release.apk \
  --macos-arm64 ../anton/packaging/macos/dist/Anton-arm64.dmg \
  --macos-intel ../anton/packaging/macos/dist/Anton-x86_64.dmg
```

| Flag | Published as |
|---|---|
| `--android` | `anton.apk` |
| `--ios` | `anton.ipa` |
| `--macos-arm64` | `Anton-arm64.dmg` |
| `--macos-intel` | `Anton-x86_64.dmg` |
| `--linux-x86` | `anton-linux-amd64.tar.gz` |

Include only the platforms you built — a release with just `--android` is fine,
and the other `latest/download` links keep pointing at whichever earlier release
last published them.

The script refuses to clobber an existing tag, rejects a platform given twice,
and generates `SHA256SUMS` across everything it uploads.

Requires the `gh` CLI, authenticated as an account with write access here.
