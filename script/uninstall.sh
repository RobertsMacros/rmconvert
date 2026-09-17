#!/bin/bash
set -euo pipefail
app="${1:-/Applications/rmconvert.app}"
[[ -d "$app" ]] || { echo 'rmconvert is not installed at this location.'; exit 0; }
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$bundle_id" == com.robertsmacros.rmconvert ]] || { echo 'This is not rmconvert.'; exit 1; }
"$app/Contents/MacOS/rmconvert" --close-setup
"$app/Contents/MacOS/rmconvert" --can-install
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app"
/usr/bin/pluginkit -e ignore -i com.robertsmacros.rmconvert.Finder
/usr/bin/pluginkit -r "$app/Contents/PlugIns/RMFinder.appex" || true
/usr/bin/pkill -x RMFinder || true
link="$HOME/.local/bin/rmconvert"
if [[ -L "$link" && "$(readlink "$link")" == "$app/Contents/MacOS/rmconvert" ]]; then /bin/rm "$link"; fi
mkdir -p "$HOME/.Trash"
/bin/mv "$app" "$HOME/.Trash/rmconvert-$(date +%Y%m%d-%H%M%S)-$$.app"
/System/Library/CoreServices/pbs -update
echo 'rmconvert moved to the Bin. Converted files, logs, preferences and shared conversion tools were kept.'
