#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source script/signing.sh
fixture_root=$(mktemp -d /private/tmp/rmconvert-signing-test.XXXXXX)
trap 'rm -rf "$fixture_root"' EXIT
unset RMCONVERT_ALLOW_IDENTITY_CHANGE
mkdir -p "$fixture_root/installed.app/Contents/MacOS"
cat > "$fixture_root/main.c" <<'C'
int main(void) { return 0; }
C
xcrun clang "$fixture_root/main.c" -o "$fixture_root/installed.app/Contents/MacOS/Test"
cat > "$fixture_root/installed.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.robertsmacros.rmconvert.signing-test</string>
<key>CFBundleExecutable</key><string>Test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
codesign --force --sign - "$fixture_root/installed.app"
installed_hash=$(shasum -a 256 "$fixture_root/installed.app/Contents/MacOS/Test")
rmconvert_check_update_identity "$fixture_root/installed.app" "$fixture_root/installed.app"
echo 'PASS: unchanged signed build accepted'
ditto "$fixture_root/installed.app" "$fixture_root/incoming.app"
/usr/libexec/PlistBuddy -c 'Set CFBundleVersion 2' "$fixture_root/incoming.app/Contents/Info.plist"
codesign --force --sign - "$fixture_root/incoming.app"
if rmconvert_check_update_identity "$fixture_root/incoming.app" "$fixture_root/installed.app"; then
    echo 'FAIL: changed identity accepted' >&2; exit 1
fi
echo 'PASS: changed ad hoc identity rejected'
rmconvert_check_update_identity "$fixture_root/incoming.app" "$fixture_root/not-installed.app"
echo 'PASS: first installation accepted'
RMCONVERT_ALLOW_IDENTITY_CHANGE=1 rmconvert_check_update_identity "$fixture_root/incoming.app" "$fixture_root/installed.app"
echo 'PASS: explicit migration override accepted with warning'
printf 'tampered' >> "$fixture_root/incoming.app/Contents/MacOS/Test"
if rmconvert_check_update_identity "$fixture_root/incoming.app" "$fixture_root/installed.app"; then
    echo 'FAIL: damaged signature accepted' >&2; exit 1
fi
echo 'PASS: damaged signature rejected'
[[ "$installed_hash" == "$(shasum -a 256 "$fixture_root/installed.app/Contents/MacOS/Test")" ]]
codesign --verify --strict "$fixture_root/installed.app"
echo 'PASS: installed fixture unchanged and signature valid'
