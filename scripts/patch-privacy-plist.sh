#!/bin/sh
# Run this ON the jailbroken device (SSH or Terminal app) after every
# ReProvision (re-)sign of Storyslice, and after every developer-cert
# rotation.
#
# ReProvision regenerates Info.plist from scratch when it signs an app,
# discarding any custom keys the build produced -- including the privacy
# usage-description strings iOS requires before touching Photos. Without
# them, PHPhotoLibrary.requestAuthorization crashes the app outright (a TCC
# kill, not a normal exception) the first time LibraryWriter tries to save.
#
# This merges the missing keys back into the *installed* bundle's Info.plist
# in place, preserving whatever ReProvision put there (mangled bundle id,
# REBundleIdentifier, etc.) via plistlib rather than overwriting the file
# outright, so it stays correct even if ReProvision's own output changes.
# Signature/resource-hash re-validation is not enforced on this jailbreak, so
# no re-signing step is needed after the edit -- confirmed by relaunching the
# patched app successfully. If a future jailbreak/AMFI update *does* start
# enforcing it, re-sign with `ldid -S<entitlements>` afterward.
set -e

if [ "$(id -u)" != "0" ]; then
    echo "Run as root: sudo sh patch-privacy-plist.sh" >&2
    exit 1
fi

COUNT=$(find /var/containers/Bundle/Application -maxdepth 2 -iname 'Storyslice.app' 2>/dev/null | wc -l)
if [ "$COUNT" -eq 0 ]; then
    echo "No installed Storyslice.app found." >&2
    exit 1
fi
if [ "$COUNT" -gt 1 ]; then
    echo "Warning: $COUNT Storyslice.app bundles found (stale installs from" >&2
    echo "before an uninstall+reinstall?). Patching the most recently" >&2
    echo "modified one; if launches still fail, uninstall via ios-mcp or" >&2
    echo "Settings and do a single fresh install first." >&2
fi
# Sorted by mtime, newest first: a directory's own mtime changes on any
# child add/remove and says nothing about which bundle is newest, so
# `find -newer <dir>` doesn't work. `stat`'s format flag differs between
# BSD (`-f '%m %N'`) and the GNU/coreutils one Procursus ships (`-c '%Y %n'`,
# since GNU's `-f` means filesystem info, not per-file format) -- try both.
BUNDLE=""
for path in $(find /var/containers/Bundle/Application -maxdepth 2 -iname 'Storyslice.app' 2>/dev/null); do
    mtime=$(stat -c '%Y' "$path" 2>/dev/null || stat -f '%m' "$path" 2>/dev/null)
    printf '%s %s\n' "$mtime" "$path"
done > /tmp/.storyslice-bundles
BUNDLE=$(sort -rn /tmp/.storyslice-bundles | head -1 | cut -d' ' -f2-)
rm -f /tmp/.storyslice-bundles

PLIST="$BUNDLE/Info.plist"
echo "Patching $PLIST"

PY=""
for candidate in python3 python3.14 python3.13 python3.12 python3.11 \
                 /var/jb/usr/local/bin/python3.14 /var/jb/usr/local/bin/python3.13 \
                 /var/jb/usr/bin/python3 /usr/local/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1; then PY="$candidate"; break; fi
    if [ -x "$candidate" ]; then PY="$candidate"; break; fi
done
if [ -z "$PY" ]; then
    echo "No python3 found on device -- install one (e.g. xyz.cypwn.python314 from Zebra) to run this." >&2
    exit 1
fi

"$PY" - "$PLIST" << 'PYEOF'
import plistlib, sys

path = sys.argv[1]
with open(path, "rb") as f:
    data = plistlib.load(f)

data.setdefault(
    "NSPhotoLibraryUsageDescription",
    "Storyslice reads the video you choose so it can split it into Story-sized clips. Nothing is uploaded.",
)
data.setdefault(
    "NSPhotoLibraryAddUsageDescription",
    "Storyslice saves the finished clips back to your library, in an album, in posting order.",
)

with open(path, "wb") as f:
    plistlib.dump(data, f)

print("OK -- keys present:", "NSPhotoLibraryUsageDescription" in data,
      "NSPhotoLibraryAddUsageDescription" in data)
PYEOF
