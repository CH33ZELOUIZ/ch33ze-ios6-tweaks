#!/usr/bin/env python3
"""Enable or disable iOS 6 SpringBoard battery percentage over SSH.

This is the safe first implementation for CH33ZE iOS 6 Tweaks. It edits
/var/mobile/Library/Preferences/com.apple.springboard.plist by copying it to the
host, changing SBShowBatteryLevel, copying it back, then respringing.
"""
from __future__ import annotations

import argparse
import datetime as dt
import plistlib
import subprocess
from pathlib import Path


def run(cmd: list[str]) -> None:
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True, help="iPod IP or hostname")
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="alpine", help="SSH password; use only on trusted LAN")
    ap.add_argument("--disable", action="store_true")
    ap.add_argument("--backup-dir", default="device-backups")
    args = ap.parse_args()

    backup_dir = Path(args.backup_dir)
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    original = backup_dir / f"com.apple.springboard.plist.{stamp}"
    modified = backup_dir / "com.apple.springboard.plist.modified"
    remote = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
    target = f"{args.user}@{args.host}:{remote}"

    ssh_opts = [
        "-o", "PreferredAuthentications=password",
        "-o", "PubkeyAuthentication=no",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "HostKeyAlgorithms=+ssh-rsa",
    ]

    run(["sshpass", "-p", args.password, "scp", *ssh_opts, target, str(original)])
    with original.open("rb") as f:
        data = plistlib.load(f)
    data["SBShowBatteryLevel"] = not args.disable
    with modified.open("wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
    run(["sshpass", "-p", args.password, "scp", *ssh_opts, str(modified), target])
    run([
        "sshpass", "-p", args.password, "ssh", *ssh_opts, f"{args.user}@{args.host}",
        "chown mobile:mobile /var/mobile/Library/Preferences/com.apple.springboard.plist; "
        "chmod 600 /var/mobile/Library/Preferences/com.apple.springboard.plist; sync; killall SpringBoard"
    ])
    print("Battery percentage", "disabled" if args.disable else "enabled")


if __name__ == "__main__":
    main()
