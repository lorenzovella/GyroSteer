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

You need **the mod** and **the app for your computer**:

| File | What |
| --- | --- |
| \`gyro_steer.zip\` | The BeamNG mod. Put it, still zipped, in BeamNG's \`mods\` folder. |
| \`GyroSteer-$version-Windows.zip\` | The app for Windows |
| \`GyroSteer-$version-macOS.zip\` | The app for macOS (BeamNG itself runs through CrossOver or another Wine wrapper) |
| \`GyroSteer-$version-Linux-x86_64.tar.gz\` | The app for Linux |

Setup and troubleshooting: see the README.
NOTES
