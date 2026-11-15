#!/bin/bash
# Scratcher mode switch for the Headache Sound WOW.
# Double-click (or run in Terminal) with the WOW connected over USB-C.
#  • Normal → Scratcher: backs up settings.txt, sets the fader to cut the beat only,
#    zeroes delay/reverb, copies the control tone (samples) and pilot (beats).
#  • Scratcher → Normal: puts everything back exactly as it was.
# Keep the two .wav files next to this script.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BACKUP="$HOME/Scratcher-WOW"
VOLROOT="${SCRATCHER_VOLUMES:-/Volumes}"   # override for testing
CTRL="00-scratcher-control.wav"
PILOT="00-scratcher-pilot.wav"
MARK=".scratcher-mode"

say()  { printf '%s\n' "$*"; }
die()  { say ""; say "✗ $*"; say ""; read -r -p "Press Return to close." _; exit 1; }
ask()  { local a; read -r -p "$1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }

# ---- find the WOW ---------------------------------------------------------------
WOW=""
for v in "$VOLROOT"/*; do
  [ -f "$v/settings.txt" ] || continue
  if grep -qi '^\[wowmachine\]' "$v/settings.txt" 2>/dev/null; then
    if [ -n "$WOW" ]; then die "Found more than one WOW-looking drive. Unplug the extras and try again."; fi
    WOW="$v"
  fi
done
[ -n "$WOW" ] || die "No WOW found. Connect it over USB-C and check it shows up in Finder (a drive with settings.txt)."
[ -d "$WOW/samples" ] && [ -d "$WOW/beats" ] || die "Found $WOW but it has no samples/ and beats/ folders."
say "WOW found at: $WOW"
say ""

# remove macOS ._ metadata files the WOW might mistake for audio
clean_dots() {
  find "$WOW/samples" "$WOW/beats" -maxdepth 1 -name '._*' -type f -delete 2>/dev/null
  rm -f "$WOW/._settings.txt" "$WOW/._$MARK" 2>/dev/null
  command -v dot_clean >/dev/null 2>&1 && dot_clean -m "$WOW" 2>/dev/null
  return 0
}

# set "key = value" in settings.txt, keeping the column alignment and line endings
setkey() {
  perl -pi -e 's/^(\Q'"$1"'\E\s*=\s*)[^\r\n]*/${1}'"$2"'/' "$WOW/settings.txt"
}

if [ ! -f "$WOW/$MARK" ]; then
  # ================= Normal → Scratcher =================
  [ -f "$HERE/$CTRL" ] && [ -f "$HERE/$PILOT" ] || die "Can't find $CTRL and $PILOT next to this script."
  say "WOW is in NORMAL mode → switching to SCRATCHER mode."
  mkdir -p "$BACKUP/parked/samples" "$BACKUP/parked/beats" || die "Couldn't create $BACKUP"
  if [ -n "$(find "$BACKUP/parked" -type f 2>/dev/null | head -1)" ]; then
    die "$BACKUP/parked still has files from an earlier run. Move them back onto the WOW (or delete them) first."
  fi
  cp -X "$WOW/settings.txt" "$BACKUP/settings-normal.txt" || die "Couldn't back up settings.txt"

  if ask "Also park your other beats & samples on this Mac (keeps the WOW lean, avoids landing on them)?"; then
    for d in samples beats; do
      for f in "$WOW/$d"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in ._*) continue ;; esac
        mv "$f" "$BACKUP/parked/$d/" || die "Couldn't move $f"
      done
    done
    say "  parked originals in $BACKUP/parked"
  fi

  cp -X "$HERE/$CTRL"  "$WOW/samples/$CTRL" || die "Couldn't copy the control tone"
  cp -X "$HERE/$PILOT" "$WOW/beats/$PILOT"  || die "Couldn't copy the pilot tone"
  setkey fader_left beat
  setkey fader_right beat
  setkey delay_strength 0
  setkey reverb_strength 0
  date > "$WOW/$MARK"
  clean_dots
  sync
  say ""
  say "✓ SCRATCHER mode. Settings changed:"
  grep -E '^(fader_left|fader_right|delay_strength|reverb_strength)' "$WOW/settings.txt" | sed 's/^/    /'
else
  # ================= Scratcher → Normal =================
  say "WOW is in SCRATCHER mode → switching back to NORMAL mode."
  [ -f "$BACKUP/settings-normal.txt" ] || die "No backup at $BACKUP/settings-normal.txt — can't restore safely."
  cp -X "$BACKUP/settings-normal.txt" "$WOW/settings.txt" || die "Couldn't restore settings.txt"
  rm -f "$WOW/samples/$CTRL" "$WOW/beats/$PILOT"
  for d in samples beats; do
    for f in "$BACKUP/parked/$d"/*; do
      [ -f "$f" ] || continue
      mv "$f" "$WOW/$d/" || die "Couldn't move $f back"
    done
  done
  rm -f "$WOW/$MARK"
  clean_dots
  sync
  say ""
  say "✓ NORMAL mode — your original settings.txt and files are back."
fi

say ""
if ask "Eject the WOW now?"; then
  diskutil eject "$WOW" >/dev/null 2>&1 && say "Ejected." || say "Couldn't eject — eject it in Finder."
fi
say "Restart the WOW so it reloads settings and files."
read -r -p "Press Return to close." _
