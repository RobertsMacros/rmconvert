#!/bin/bash
# Shared build/install checks. This file never changes macOS permissions.
rmconvert_check_update_identity() {
    local incoming="$1" installed="$2" requirement
    [[ -d "$installed" ]] || return 0
    requirement=$(/usr/bin/codesign -d -r- "$installed" 2>&1 | /usr/bin/sed -n 's/.*designated => //p' || true)
    if [[ -n "$requirement" ]] && /usr/bin/codesign --verify --strict -R "=$requirement" "$incoming" >/dev/null 2>&1; then
        return 0
    fi
    if [[ "${RMCONVERT_ALLOW_IDENTITY_CHANGE:-0}" == 1 ]]; then
        echo 'Warning: this update changes signing identity. macOS may request folder access again.' >&2
        return 0
    fi
    echo 'Update stopped: the new build does not match the installed signing identity.' >&2
    echo 'The installed app and its existing folder permissions have been kept.' >&2
    echo 'Use the same signing certificate through RMCONVERT_SIGNING_IDENTITY for future builds.' >&2
    echo 'For an intentional identity migration only, set RMCONVERT_ALLOW_IDENTITY_CHANGE=1 and expect macOS to ask for access again.' >&2
    return 1
}
