#!/bin/bash
# SiteStream Pi Client — "No Scheduled Content" Multicast Placeholder Generator
#
# Produces a short, looping MPEG-2 Program Stream clip that player.sh feeds
# to the multicast broadcast the same way it feeds a real scheduled video,
# whenever nothing is actually scheduled right now (see get_current_video's
# own comment on the schedule-boundary bug this pairs with). Exists for one
# reason: confirmed live that SMARTBOX's receiver locks up and needs a
# manual power-cycle to recover from a full VLC cold-start restart (an
# ~9-30s complete gap in multicast output — see player.sh's own comment on
# the packet-capture measurements). Previously, "nothing scheduled" meant
# stopping the multicast process outright (see start_vlc's no-multicast
# path) — harmless in isolation, but it turned the NEXT schedule transition
# (real content reappearing) into exactly that kind of cold restart, right
# when a receiver would be watching for continuity. Swapping in this
# placeholder instead means the multicast process never actually stops:
# every transition, including into and out of a "nothing scheduled" state,
# goes through the same live RC swap real content changes already use (see
# swap_multicast_video) — gapless either way.
#
# Same MPEG-2 encode profile as the real transcode pipeline (both
# packages/api/src/services/multicastTranscode.ts on the cloud side and
# pi-portal/server/src/multicastTranscode.ts locally) — SMARTBOX only
# decodes MPEG-2, not H.264 (see player.sh's own multicast comments for that
# whole saga), and matching the real profile means this is exactly as valid
# a stream as any real content, not a special case the receiver has to
# tolerate differently.
#
# Idempotent, same pattern as generate-idle-screen.sh: the rendered content
# never changes (just this device's serial number, fixed at generation
# time), so this only actually re-runs ffmpeg once per device rather than on
# every loop tick. Pass FORCE=1 to regenerate anyway.

set -e

SITESTREAM_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$SITESTREAM_DIR/no-schedule-multicast.mpg"

if [ -f "$OUTPUT" ] && [ "$FORCE" != "1" ]; then
  exit 0
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg not installed — cannot generate the no-schedule multicast placeholder. Re-run install.sh." >&2
  exit 1
fi

SERIAL=$(awk -F': ' '/^Serial/ {print $2}' /proc/cpuinfo | tr -d ' \n')

FONT_BOLD="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
FONT_REGULAR="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

TMP_OUTPUT="$OUTPUT.tmp"

# 30s, not shorter — this loops via VLC's own --loop exactly like real
# content (see start_multicast), and confirmed live that a clean loop
# wraparound isn't the risk here (PCR stays monotonic across one — see
# player.sh's own comment on that capture). The real risk is the FIRST loop
# right after this file gets swapped in: confirmed live that VLC's --loop
# can leave a freshly swapped-in video stopped after its first playthrough
# instead of correctly restarting it, when that first playthrough finishes
# close to when swap_multicast_video's own add+delete RC sequence is still
# settling (player.sh's own watchdog catches and recovers from this either
# way, but giving it more runway before that first boundary makes it less
# likely to happen at all). 30s is comfortably past any realistic swap
# settling time without meaningfully increasing generation time or disk
# space — nothing rendered here ever changes, so there's no other cost to
# a longer clip.
#
# -f lavfi color/anullsrc sources, not a static PNG re-encoded — this device
# already generates PNGs for the idle/onboarding/rescue screens (see
# generate-idle-screen.sh and friends), but multicast needs an actual
# MPEG-2 Program Stream file, not an image, so this renders the equivalent
# content directly as video instead of routing through those scripts' own
# output.
ffmpeg -y \
  -f lavfi -i "color=c=0x0f172a:s=1280x720:r=30" \
  -f lavfi -i "anullsrc=r=48000:cl=stereo" \
  -t 30 \
  -vf "drawtext=fontfile=$FONT_BOLD:text='No Scheduled Content':fontcolor=0xe2e8f0:fontsize=64:x=(w-text_w)/2:y=(h-text_h)/2-50,drawtext=fontfile=$FONT_REGULAR:text='Serial Number\\: $SERIAL':fontcolor=0x94a3b8:fontsize=34:x=(w-text_w)/2:y=(h-text_h)/2+50" \
  -c:v mpeg2video \
  -pix_fmt yuv420p \
  -b:v 5000k \
  -maxrate 6000k \
  -bufsize 1835k \
  -g 15 \
  -bf 2 \
  -qmin:v 2 \
  -qmax:v 31 \
  -c:a mp2 \
  -b:a 192k \
  -ar 48000 \
  -ac 2 \
  -f mpeg \
  "$TMP_OUTPUT"

# Atomic rename, not a direct write to OUTPUT — same reasoning as every
# other atomic-write-then-rename in this codebase (see e.g. sync.sh's own
# downloads): player.sh could otherwise pick up a half-written file if it
# happens to check between ffmpeg starting and finishing.
mv "$TMP_OUTPUT" "$OUTPUT"
