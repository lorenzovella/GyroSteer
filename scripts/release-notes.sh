#!/bin/bash
# Prints the release notes for a version: its CHANGELOG.md section, then which file to download.
#   scripts/release-notes.sh 0.3.0
set -euo pipefail
cd "$(dirname "$0")/.."
version="$1"
awk -v v="$version" '
  /^## / { if (found) exit; if (index($0, "## " v) == 1) { found = 1; next } }
  found { print }
' CHANGELOG.md
cat <<NOTES

### Which files?

Download the app for your computer. Each one also contains the BeamNG mod, \`gyro_steer.zip\`: put it, still
zipped, in BeamNG's \`mods\` folder.

| File | What |
| --- | --- |
| \`GyroSteer-$version-Windows.zip\` | The app for Windows, and the mod |
| \`GyroSteer-$version-macOS.zip\` | The app for macOS (BeamNG itself runs through CrossOver or another Wine wrapper), and the mod |
| \`GyroSteer-$version-Linux-x86_64.tar.gz\` | The app for Linux, and the mod |
| \`gyro_steer.zip\` | Just the mod |

Setup and troubleshooting: see the README.
NOTES
