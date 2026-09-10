#!/usr/bin/env python3
"""Validate the embedded watch companion in a built iPhone app or archive."""
import plistlib
import sys
from pathlib import Path


def validate(app: Path) -> None:
    phone = plistlib.loads((app / "Info.plist").read_bytes())
    watch = app / "Watch" / "SparkWatch.app"
    info = plistlib.loads((watch / "Info.plist").read_bytes())
    assert info["WKCompanionAppBundleIdentifier"] == phone["CFBundleIdentifier"], "Companion identifier mismatch"
    for key in ("CFBundleVersion", "CFBundleShortVersionString"):
        assert info[key] == phone[key], f"Watch and iPhone {key} differ"
    assert info["WKApplication"] is True, "Missing watch application marker"
    assert info["UIDeviceFamily"] == [4], "Watch device family was overridden by the iPhone archive"
    assert info.get("WKSupportsRunningWithoutiOSApp") is False, "Companion dependency must be declared"
    assert (watch / info["CFBundleExecutable"]).is_file(), "Watch executable missing"
    assert (watch / "Assets.car").is_file(), "Watch assets missing"
    privacy = plistlib.loads((watch / "PrivacyInfo.xcprivacy").read_bytes())
    assert privacy["NSPrivacyTracking"] is False, "Unexpected tracking declaration"


if __name__ == "__main__":
    validate(Path(sys.argv[1]))
    print("Watch companion packaging verified")
