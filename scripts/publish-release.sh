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
# Platforms rarely finish building together — the Mac build can land hours after
# the Android one, and each toolchain runs on its own machine. `--add` puts a
# late artifact into a release that already exists, leaving the published assets
# untouched and reissuing SHA256SUMS so it covers old and new alike:
#
#   ./scripts/publish-release.sh --add v1.0.1 \
#       --targetos android ../anton/mobile/build/app/outputs/flutter-apk/app-release.apk
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
usage: $0 [--add] <tag> --targetos <os> <file> [--targetos <os> <file>...]

  --add   upload into an existing release instead of creating one, for a
          platform whose build finished later

target os values:
  android       published as anton.apk
  ios           published as anton.ipa
  macos-arm64   published as Anton-arm64.dmg
  macos-intel   published as Anton-x86_64.dmg
  linux-x86     published as anton-linux-amd64.tar.gz

examples:
  $0 v1.0.1 --targetos android ../anton/mobile/build/app/outputs/flutter-apk/app-release.apk
  $0 --add v1.0.1 --targetos macos-arm64 ../anton/packaging/macos/dist/Anton-arm64.dmg
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
case "$1" in --help|-h) usage ;; esac

# Only accepted ahead of the tag. Later it would sit inside the `--targetos <os>
# <file>` triples, where a stray flag is a typo worth rejecting rather than a
# mode switch.
ADD=false
if [[ "$1" == "--add" ]]; then
  ADD=true; shift
fi

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

if $ADD; then
  gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 \
    || die "release $TAG does not exist — publish it first, without --add."

  # Adding is strictly additive. Replacing a file people may already have
  # downloaded is a deliberate act, not something that should happen as a side
  # effect of uploading a sibling platform.
  PUBLISHED=$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name')
  for asset in "${ASSETS[@]}"; do
    if grep -qxF "$asset" <<<"$PUBLISHED"; then
      die "release $TAG already publishes $asset — delete that asset first, or pick a new tag."
    fi
  done
else
  # Refuse to overwrite a published release by accident.
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    die "release $TAG already exists. Delete it first, add to it with --add, or pick a new tag."
  fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Holds exactly what gets uploaded, so the upload can glob the directory. Working
# files stay in $TMP alongside it, never in here.
STAGE="$TMP/assets"
mkdir "$STAGE"

echo "Staging artifacts…"
for i in "${!FILES[@]}"; do
  cp "${FILES[$i]}" "$STAGE/${ASSETS[$i]}"
  printf '  %-13s %-26s %s\n' \
    "${OSES[$i]}" "${ASSETS[$i]}" "$(du -h "${FILES[$i]}" | cut -f1)"
done

echo "Computing checksums…"
# SHA256SUMS must name every asset in the release, not just the ones uploaded in
# this run, or `-c` stops covering the platforms published earlier. Under --add
# the existing file is the starting point: this script wrote it, so its lines are
# already in the right format under the published asset names.
PREVIOUS="$TMP/published.sums"
: > "$PREVIOUS"
if $ADD; then
  # Whether the file is there is decided from the asset list already fetched, not
  # from the exit status of the download. A network or auth failure would
  # otherwise be indistinguishable from "this release has no SHA256SUMS", and the
  # run would quietly publish a checksum file listing only the new artifact —
  # dropping every platform released earlier.
  if grep -qxF SHA256SUMS <<<"$PUBLISHED"; then
    gh release download "$TAG" --repo "$REPO" --pattern SHA256SUMS --dir "$TMP" \
      || die "could not download the published SHA256SUMS for $TAG"
    mv "$TMP/SHA256SUMS" "$PREVIOUS"
  else
    echo "  no published SHA256SUMS to extend — writing a fresh one"
  fi
fi

# Hashed from inside $STAGE so the file column is a bare asset name, and written
# outside it so the output can never list itself. The `./` prefix guards a
# filename that begins with a dash; sed strips it back off so the published
# SHA256SUMS names the assets plainly. Matched after the two-space separator,
# never anchored to the line start — each line begins with the hash, so `^\./`
# matches nothing and the prefix ships to users. Not `sed -i` either: BSD sed
# (macOS) reads the expression as a backup suffix and fails with "invalid
# command code", aborting under `set -e` after staging but before any upload.
( cd "$STAGE" && sha256 ./* > "$TMP/staged.sums" )
sed 's|  \./|  |' "$TMP/staged.sums" > "$TMP/staged.clean"

# Drop any published line naming a file being uploaded now, so the merge cannot
# emit two lines for one asset. The guard above already rejects re-uploading a
# published asset; this covers repairing a release whose asset was deleted by
# hand while its checksum line stayed behind. A leading `./` is normalised away
# first, so a line written by an older version of this script is still matched.
# Asset names never contain spaces, which is what makes the membership test safe.
awk -v staged=" ${ASSETS[*]} " '
  { name = $2; sub(/^\.\//, "", name)
    if (index(staged, " " name " ") == 0) print }
' "$PREVIOUS" > "$TMP/previous.kept"

sort -k2 "$TMP/previous.kept" "$TMP/staged.clean" > "$STAGE/SHA256SUMS"
cat "$STAGE/SHA256SUMS"

# Braced deliberately: macOS ships bash 3.2, which absorbs the leading byte of
# the following multibyte character into the variable name — `$TAG…` parses as
# an unset `${TAG\xe2\x80\xa6}` and aborts under `set -u`, after the artifacts
# are staged and checksummed but before the release is created. Newer bash on
# Linux stops at the non-identifier byte, which is why this only bites on a Mac.
if $ADD; then
  echo "Uploading to ${TAG}…"
  # --clobber is here for SHA256SUMS, which is replaced every time. The artifacts
  # were checked against the published asset list above, so none of them can be
  # silently overwriting anything.
  gh release upload "$TAG" --repo "$REPO" --clobber "$STAGE"/*
else
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
fi

echo
echo "Done: https://github.com/$REPO/releases/tag/$TAG"
echo "The website's 'latest' links now resolve to this release."
