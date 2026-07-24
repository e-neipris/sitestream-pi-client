#!/bin/bash
# Builds a release tarball the same way every time.
#
# Introduced after two release-process bugs in one afternoon of hand-built
# tarballs: an already-issued version number got silently overwritten with
# different content (see git history/PR notes around 1.42), and a release
# shipped without the VERSION file install.sh needs to stamp
# .installed_version on a fresh install (see install.sh's own comment on
# that). Both were hand-packaging mistakes; this script makes them
# impossible by construction instead of relying on remembering the steps.
set -e

VERSION="$1"
if [ -z "$VERSION" ]; then
  echo "Usage: bash make-release.sh <version> [--notes \"text\"] [--grade ALPHA|BETA|GA]"
  echo "  (e.g. bash make-release.sh 1.53 --notes \"Fixes X\" --grade BETA)"
  exit 1
fi
shift

NOTES=""
GRADE="ALPHA"
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --grade) GRADE="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done
case "$GRADE" in
  ALPHA|BETA|GA) ;;
  *) echo "ERROR: --grade must be ALPHA, BETA, or GA (got '$GRADE') — matches the SaaS's own ReleaseGrade type."; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OUT="Releases/sitestream-pi-client-$VERSION.tar.gz"
if [ -e "$OUT" ]; then
  echo "ERROR: $OUT already exists — pick a new version instead of overwriting an already-issued release."
  exit 1
fi

echo "Building pi-portal/server…"
(cd pi-portal/server && npm install --no-audit --no-fund >/dev/null && npm run build)

echo "Building pi-portal/web…"
(cd pi-portal/web && npm install --no-audit --no-fund >/dev/null && npm run build)

# Bare version number (e.g. "1.46"), no trailing newline, no
# "sitestream-pi-client-" prefix — matches the format sync.sh's cloud
# manifest compares against (see sync.sh's UPDATE_VERSION), not the
# "sitestream-pi-client-<version>" form the portal's own firmware-upload
# handler derives from an uploaded filename. Removed after packaging either
# way — this is a build artifact, not something to leave sitting in the repo.
printf '%s' "$VERSION" > VERSION

# release.json — structured metadata for the SaaS's own PiRelease upload to
# read directly from the tarball, instead of an admin retyping the version
# (and notes/grade) by hand into a free-text form field. Introduced after
# exactly that manual step caused a real production incident: a release
# built as "1.50" got uploaded with its version label typed as "1.5" — a
# one-character slip — which desynced the SaaS's release catalog from what
# was actually in the tarball and put a live device into a permanent
# self-update loop (see install.sh's "Installed version stamp" comment for
# the full mechanism). VERSION above still ships unchanged for player-side
# consumption (install.sh/sync.sh only ever want a bare string); this is
# additive, purely for whatever uploads this tarball to read version/notes/
# grade from the one place they can't drift from what's actually inside.
jq -n \
  --arg version "$VERSION" \
  --arg notes "$NOTES" \
  --arg grade "$GRADE" \
  --arg builtAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{version: $version, notes: (if $notes == "" then null else $notes end), grade: $grade, builtAt: $builtAt}' \
  > release.json

trap 'rm -f VERSION release.json' EXIT

mkdir -p Releases

# Every top-level script except this one — new scripts get picked up
# automatically instead of needing this list hand-maintained (that drift is
# exactly how the VERSION file got forgotten from a release in the first
# place).
SCRIPTS=$(ls *.sh | grep -v '^make-release\.sh$')

tar -czf "$OUT" \
  $SCRIPTS VERSION release.json \
  pi-portal/server/dist pi-portal/server/package.json pi-portal/web-dist

echo "Wrote $OUT"
