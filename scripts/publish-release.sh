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

# sha256sum is GNU coreutils. Linux has it; macOS ships `shasum` instead and
# only recent builds carry a sha256sum at all, so pick whichever exists rather
# than assuming. Both write and verify the same "<hash>  <file>" format, so the
# SHA256SUMS produced here is checkable with either tool on either platform.
# Resolved before any work happens, so a missing tool fails immediately instead
# of after the artifacts are staged.
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$@"; }
else
  die "need sha256sum or shasum to checksum the artifacts"
fi

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
# Two steps through a temp file rather than `sed -i` in place: BSD sed (macOS)
# reads the expression as the backup suffix and fails with "invalid command
# code", aborting the publish under `set -e` after staging but before the
# release is created.
#
# Not a pipeline either. `sha256 ./* > FILE` is a simple command, so the shell
# expands the glob before performing the redirection and the output file cannot
# list itself. In a pipeline the glob and the redirect are set up in separately
# forked processes, leaving that ordering to the shell's discretion.
#
# The `./` prefix guards a filename that begins with a dash; sed strips it back
# off so the published SHA256SUMS names the assets plainly.
( cd "$STAGE" \
    && sha256 ./* > SHA256SUMS.tmp \
    && sed 's|\./||' SHA256SUMS.tmp > SHA256SUMS \
    && rm -f SHA256SUMS.tmp )
cat "$STAGE/SHA256SUMS"

# Braced deliberately: macOS ships bash 3.2, which absorbs the leading byte of
# the following multibyte character into the variable name — `$TAG…` parses as
# an unset `${TAG\xe2\x80\xa6}` and aborts under `set -u`, after the artifacts
# are staged and checksummed but before the release is created. Newer bash on
# Linux stops at the non-identifier byte, which is why this only bites on a Mac.
echo "Creating release ${TAG}…"
gh release create "$TAG" \
  --repo "$REPO" \
  --title "Anton $TAG" \
  --notes "Anton $TAG

Verify downloads against \`SHA256SUMS\`:

    sha256sum -c SHA256SUMS --ignore-missing     # Linux
    shasum -a 256 -c SHA256SUMS --ignore-missing # macOS

macOS builds are unsigned — see the README for the Gatekeeper steps." \
  "$STAGE"/*

echo
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
echo "The website's 'latest' links now resolve to this release."
