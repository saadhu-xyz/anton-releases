#!/usr/bin/env bash
# Publish an Anton release: checksum the artifacts, create the tag + release,
# and upload everything as release assets.
#
# Each artifact is passed behind a flag naming the platform it's for. The flag
# decides the published filename, so you can hand it build output under whatever
# name the toolchain produced:
#
#   ./scripts/publish-release.sh v1.0.1 \
#       --android     ../anton/mobile/build/app/outputs/flutter-apk/app-release.apk \
#       --macos-arm64 ../anton/packaging/macos/dist/Anton-arm64.dmg
#
# Requires the `gh` CLI, authenticated with write access to this repo.
set -euo pipefail

REPO="saadhu-xyz/anton-releases"

# Platform flag -> the filename the website links to via `latest/download/<name>`.
# These names are load-bearing; changing one breaks the site's download button.
platform_asset() {
  case "$1" in
    --android)     echo "anton.apk" ;;
    --ios)         echo "anton.ipa" ;;
    --macos-arm64) echo "Anton-arm64.dmg" ;;
    --macos-intel) echo "Anton-x86_64.dmg" ;;
    --linux-x86)   echo "anton-linux-amd64.tar.gz" ;;
    *)             return 1 ;;
  esac
}

PLATFORMS="--android --ios --macos-arm64 --macos-intel --linux-x86"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
usage: $0 <tag> --<platform> <file> [--<platform> <file>...]

platforms:
  --android      <file>   published as anton.apk
  --ios          <file>   published as anton.ipa
  --macos-arm64  <file>   published as Anton-arm64.dmg
  --macos-intel  <file>   published as Anton-x86_64.dmg
  --linux-x86    <file>   published as anton-linux-amd64.tar.gz

example:
  $0 v1.0.1 --android ../anton/mobile/build/app/outputs/flutter-apk/app-release.apk
EOF
  exit 1
}

[[ $# -ge 3 ]] || usage

TAG="$1"; shift
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "tag must look like v1.2.3 (got: $TAG)"

# Parse --platform/file pairs.
FLAGS=(); FILES=(); ASSETS=()
while [[ $# -gt 0 ]]; do
  flag="$1"
  case "$flag" in
    --help|-h) usage ;;
    --*) ;;
    *) die "expected a platform flag, got '$flag'. One of: $PLATFORMS" ;;
  esac

  asset=$(platform_asset "$flag") || die "unknown platform flag '$flag'. One of: $PLATFORMS"

  [[ $# -ge 2 ]] || die "$flag needs a file path"
  file="$2"; shift 2

  [[ "$file" != --* ]] || die "$flag needs a file path, got flag '$file'"
  [[ -f "$file" ]]     || die "not a file: $file"
  [[ -s "$file" ]]     || die "empty file: $file"

  for seen in ${FLAGS[@]+"${FLAGS[@]}"}; do
    [[ "$seen" == "$flag" ]] && die "$flag given twice — one file per platform"
  done

  FLAGS+=("$flag"); FILES+=("$file"); ASSETS+=("$asset")
done

[[ ${#FILES[@]} -gt 0 ]] || die "no artifacts given. Platforms: $PLATFORMS"

command -v gh >/dev/null || die "gh CLI not found — https://cli.github.com"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

# Refuse to overwrite a published release by accident.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "release $TAG already exists. Delete it first, or pick a new tag."
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "Staging artifacts…"
for i in "${!FILES[@]}"; do
  cp "${FILES[$i]}" "$STAGE/${ASSETS[$i]}"
  printf '  %-14s %-26s %s\n' \
    "${FLAGS[$i]}" "${ASSETS[$i]}" "$(du -h "${FILES[$i]}" | cut -f1)"
done

echo "Computing checksums…"
( cd "$STAGE" && sha256sum ./* > SHA256SUMS && sed -i 's|\./||' SHA256SUMS )
cat "$STAGE/SHA256SUMS"

echo "Creating release $TAG…"
gh release create "$TAG" \
  --repo "$REPO" \
  --title "Anton $TAG" \
  --notes "Anton $TAG

Verify downloads against \`SHA256SUMS\`:

    sha256sum -c SHA256SUMS --ignore-missing

macOS builds are unsigned — see the README for the Gatekeeper steps." \
  "$STAGE"/*

echo
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
echo "The website's 'latest' links now resolve to this release."
