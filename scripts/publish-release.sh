#!/usr/bin/env bash
# Publish an Anton release: checksum the artifacts, create the tag + release,
# and upload everything as release assets.
#
# Usage:
#   ./scripts/publish-release.sh v1.0.1 path/to/anton.apk [more artifacts...]
#
# Requires the `gh` CLI, authenticated with write access to this repo.
set -euo pipefail

REPO="saadhu-xyz/anton-releases"

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 2 ]] || die "usage: $0 <tag> <artifact> [artifact...]"

TAG="$1"; shift
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] || die "tag must look like v1.2.3 (got: $TAG)"

command -v gh >/dev/null || die "gh CLI not found — https://cli.github.com"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; run: gh auth login"

# Refuse to overwrite a published release by accident.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "release $TAG already exists. Delete it first, or pick a new tag."
fi

# Toolchains name their output for the build, not for us: Flutter emits
# `app-release.apk`, Go tarballs come out arch-suffixed, etc. The website links
# to fixed filenames via `latest/download/<name>`, so normalize on the way in
# rather than making every release depend on remembering to rename by hand.
canonical_name() {
  case "$1" in
    app-release.apk|anton-release.apk) echo "anton.apk" ;;
    app-arm64-v8a-release.apk)         echo "anton.apk" ;;
    *)                                 echo "$1" ;;
  esac
}

# Validate every artifact up front — no partial uploads.
ARTIFACTS=()
NAMES=()
for f in "$@"; do
  [[ -f "$f" ]] || die "not a file: $f"
  [[ -s "$f" ]] || die "empty file: $f"
  name=$(canonical_name "$(basename "$f")")

  # Two inputs landing on one asset name would silently drop one upload.
  for existing in ${NAMES[@]+"${NAMES[@]}"}; do
    [[ "$existing" == "$name" ]] && die "two artifacts both map to '$name' — pass only one"
  done

  ARTIFACTS+=("$f")
  NAMES+=("$name")
done

# Warn on names the website's DOWNLOADS map doesn't expect. The `latest/download`
# URLs are keyed on exact filenames, so an unrecognized name silently breaks the
# site. Checked after normalization, so a known rename is not flagged.
KNOWN="anton.apk Anton-arm64.dmg Anton-x86_64.dmg anton-linux-amd64.tar.gz anton-linux-arm64.tar.gz"
for name in "${NAMES[@]}"; do
  case " $KNOWN " in
    *" $name "*) ;;
    *) echo "warning: '$name' is not a filename the website links to." >&2
       echo "         expected one of: $KNOWN" >&2 ;;
  esac
done

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "Staging artifacts…"
for i in "${!ARTIFACTS[@]}"; do
  f="${ARTIFACTS[$i]}"
  name="${NAMES[$i]}"
  base=$(basename "$f")
  cp "$f" "$STAGE/$name"
  if [[ "$base" == "$name" ]]; then
    printf '  %-30s %s\n' "$name" "$(du -h "$f" | cut -f1)"
  else
    printf '  %-30s %s  (renamed from %s)\n' "$name" "$(du -h "$f" | cut -f1)" "$base"
  fi
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
