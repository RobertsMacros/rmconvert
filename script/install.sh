#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source_app="/private/tmp/rmconvert-build-${UID}/rmconvert.app"
if [[ ! -d "$source_app" ]]; then ./script/build_and_run.sh --build-only; fi
destination="${1:-/Applications}"
mkdir -p "$destination" "$HOME/.local/bin"
target="$destination/rmconvert.app"
if [[ -e "$target" ]]; then
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")
    [[ "$bundle_id" == com.robertsmacros.rmconvert ]] || { echo 'Another app already uses this name.'; exit 1; }
    "$source_app/Contents/MacOS/rmconvert" --close-setup
    "$source_app/Contents/MacOS/rmconvert" --can-install
    /usr/bin/pluginkit -e ignore -i com.robertsmacros.rmconvert.Finder
    /usr/bin/pluginkit -r "$target/Contents/PlugIns/RMFinder.appex" || true
    /usr/bin/pkill -x RMFinder || true
fi
/usr/bin/ditto "$source_app" "$target"
/usr/bin/codesign --verify --deep --strict "$target"
ln -sfn "$target/Contents/MacOS/rmconvert" "$HOME/.local/bin/rmconvert"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$target"
/usr/bin/pluginkit -a "$target/Contents/PlugIns/RMFinder.appex"
/usr/bin/pluginkit -e use -i com.robertsmacros.rmconvert.Finder
/usr/bin/open -n "$target"
echo "Installed: $target"
echo 'Enable rmconvert in Finder extensions using Open Finder settings in the app.'
