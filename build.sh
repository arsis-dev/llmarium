#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$project_dir"
swift build -c release "$@"
bundle="$project_dir/dist/Modèles locaux.app"
# Start from an empty bundle so that removed files do not linger.
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/LocalModelLauncher "$bundle/Contents/MacOS/LocalModelLauncher"
# The CLI ships inside the app so MCP clients can point at a stable path.
cp .build/release/lml "$bundle/Contents/MacOS/lml"
/usr/bin/plutil -lint Resources/Info.plist
cp Resources/Info.plist "$bundle/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$bundle/Contents/MacOS/lml"
/usr/bin/codesign --force --sign - "$bundle"
printf '%s\n' "$bundle"
