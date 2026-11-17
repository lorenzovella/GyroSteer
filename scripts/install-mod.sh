#!/bin/bash
# For development: copies the mod, unpacked, into a BeamNG mods folder, so edits show up after a game restart.
#   BEAMNG_MODS=/path/to/BeamNG.drive/current/mods scripts/install-mod.sh
# Without BEAMNG_MODS it tries the usual Windows/Linux user folders and a Wineskin wrapper at ~/Applications/beamng.app.
set -euo pipefail
cd "$(dirname "$0")/.."
candidates=(
  "${BEAMNG_MODS:-}"
  "${LOCALAPPDATA:-/nonexistent}/BeamNG/BeamNG.drive/current/mods"
  "$HOME/.local/share/BeamNG/BeamNG.drive/current/mods"
  "$HOME/Applications/beamng.app/Contents/SharedSupport/prefix/drive_c/users/Wineskin/AppData/Local/BeamNG/BeamNG.drive/current/mods"
)
MODS=""
for c in "${candidates[@]}"; do
  if [ -n "$c" ] && [ -d "$c" ]; then MODS="$c"; break; fi
done
if [ -z "$MODS" ]; then
  echo "Couldn't find BeamNG's mods folder; set BEAMNG_MODS to it." >&2
  exit 1
fi
mkdir -p "$MODS/unpacked"
rsync -a --delete --exclude .DS_Store mod/gyro_steer/ "$MODS/unpacked/gyro_steer/"
echo "Installed the mod in $MODS/unpacked/gyro_steer (restart BeamNG if it's running)"
