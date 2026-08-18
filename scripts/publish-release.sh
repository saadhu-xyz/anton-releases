#!/usr/bin/env bash
# Publish an Anton release: checksum the artifacts, create the tag + release,
# and upload everything as release assets.
#
# Each artifact is passed with the target OS it was built for. The target decides
# the published filename, so you can hand it build output under whatever name the
# toolchain produced:
#
#   ./scripts/publish-release.sh v1.0.1 \
#       --targetos android     ../anton/mobile/build/app/outputs/flutter-apk/app-release.apk \
#       --targetos macos-arm64 ../anton/packaging/macos/dist/Anton-arm64.dmg
#
# Requires the `gh` CLI, authenticated with write access to this repo.
set -euo pipefail

REPO="saadhu-xyz/anton-releases"

# Target OS -> the filename the website links to via `latest/download/<name>`.
# These names are load-bearing; changing one breaks the site's download button.
target_asset() {
  case "$1" in
    android)     echo "anton.apk" ;;
    ios)         echo "anton.ipa" ;;
    macos-arm64) echo "Anton-arm64.dmg" ;;
    macos-intel) echo "Anton-x86_64.dmg" ;;
    linux-x86)   echo "anton-linux-amd64.tar.gz" ;;
    *)           return 1 ;;
  esac
}

TARGETS="android ios macos-arm64 macos-intel linux-x86"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat >&2 <<EOF
usage: $0 <tag> --targetos <os> <file> [--targetos <os> <file>...]

target os values:
  android       published as anton.apk
  ios           published as anton.ipa
  macos-arm64   published as Anton-arm64.dmg
  macos-intel   published as Anton-x86_64.dmg
  linux-x86     published as anton-linux-amd64.tar.gz

example:
  $0 v1.0.1 --targetos android ../anton/mobile/build/app/outputs/flutter-apk/app-release.apk
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
case "$1" in --help|-h) usage ;; esac
[[ $# -ge 4 ]] || usage

TAG="$1"; shift
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "tag must look like v1.2.3 (got: $TAG)"

# Parse repeated `--targetos <os> <file>` triples.
OSES=(); FILES=(); ASSETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)  usage ;;
    --targetos) ;;
    *)          die "expected --targetos, got '$1'" ;;
  esac

  [[ $# -ge 3 ]] || die "--targetos needs an os and a file path"
  os="$2"; file="$3"; shift 3

  asset=$(target_asset "$os") || die "unknown target os '$os'. One of: $TARGETS"

  [[ "$file" != --* ]] || die "--targetos $os needs a file path, got flag '$file'"
  [[ -f "$file" ]]     || die "not a file: $file"
  [[ -s "$file" ]]     || die "empty file: $file"

  for seen in ${OSES[@]+"${OSES[@]}"}; do
    [[ "$seen" == "$os" ]] && die "--targetos $os given twice — one file per target"
  done

  OSES+=("$os"); FILES+=("$file"); ASSETS+=("$asset")
done

[[ ${#FILES[@]} -gt 0 ]] || die "no artifacts given. Target os values: $TARGETS"

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
  printf '  %-13s %-26s %s\n' \
    "${OSES[$i]}" "${ASSETS[$i]}" "$(du -h "${FILES[$i]}" | cut -f1)"
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
