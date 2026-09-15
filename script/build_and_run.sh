#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-}"
case "$mode" in ''|--build-only|--verify|--logs|--telemetry) ;; *) echo 'Use --build-only, --verify, --logs or --telemetry'; exit 2;; esac
app="/private/tmp/rmconvert-build-${UID}/rmconvert.app"
if [[ -x "$app/Contents/MacOS/rmconvert" ]]; then "$app/Contents/MacOS/rmconvert" --close-setup 2>/dev/null || true; fi
ext="$app/Contents/PlugIns/RMFinder.appex"
mkdir -p outputs work/build work/swift-module-cache "$app/Contents/MacOS" "$app/Contents/Resources" "$ext/Contents/MacOS" "$ext/Contents/Resources"
flags=(-swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$PWD/work/swift-module-cache" -O)
xcrun swiftc "${flags[@]}" Sources/Shared/*.swift Sources/CLI/main.swift -o "$app/Contents/MacOS/rmconvert"
xcrun clang -O2 Sources/CLI/exec_group.c -o "$app/Contents/MacOS/rmconvert-exec"
xcrun swiftc "${flags[@]}" -parse-as-library Sources/Shared/*.swift Sources/App/*.swift -o "$app/Contents/MacOS/RMConvertApp"
xcrun swiftc "${flags[@]}" -parse-as-library -application-extension -module-name RMFinder Sources/Shared/Catalog.swift Sources/Shared/Brand.swift Sources/Extension/*.swift -Xlinker -e -Xlinker _NSExtensionMain -o "$ext/Contents/MacOS/RMFinder"
cp Resources/manifest.json "$app/Contents/Resources/"
cp Resources/manifest.json "$ext/Contents/Resources/"
cp Resources/RobertsMacros.png "$app/Contents/Resources/"
cp Resources/RobertsMacros.png "$ext/Contents/Resources/"
python3 script/package.py "$app"
codesign --force --sign - "$app/Contents/MacOS/rmconvert"
codesign --force --sign - "$app/Contents/MacOS/rmconvert-exec"
codesign --force --sign - --entitlements Resources/Finder.entitlements "$ext"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
"$app/Contents/MacOS/rmconvert" --validate
/usr/bin/ditto -c -k --keepParent "$app" "$PWD/outputs/rmconvert.zip"
if [[ "$mode" == --build-only ]]; then exit 0; fi
/usr/bin/open -n "$app"
if [[ "$mode" == --verify ]]; then
    /usr/bin/pgrep -x RMConvertApp
elif [[ "$mode" == --logs ]]; then
    /usr/bin/log stream --level info --predicate 'process == "RMConvertApp" OR process == "RMFinder"'
elif [[ "$mode" == --telemetry ]]; then
    /usr/bin/log stream --level info --predicate 'subsystem BEGINSWITH "com.robertsmacros.rmconvert"'
fi
