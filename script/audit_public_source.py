#!/usr/bin/env python3
"""Check the public source allowlist and common credential/privacy patterns.

This is a local guardrail, not a complete secret detector or a media audit.
"""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_DIRS = {"Sources", "Tests", "Resources", "docs", "script", ".github"}
ALLOWED_FILES = {
    "Package.swift", "README.md", "README.zh-CN.md", "LICENSE", "CITATION.cff",
    "CONTRIBUTING.md", "SECURITY.md", ".gitignore",
}
RULES = {
    "private key": re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
    "access token": re.compile(r"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{25,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{20,})"),
    "personal home path": re.compile(r"/" r"Users/(?!test(?:/|\b))[^/\s]+"),
    "private network address": re.compile(r"\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b"),
    "personal signing default": re.compile(r"Apple Development:\s+[^\s\"']"),
    "hardware identity dump": re.compile(r"(?i)(?:Serial Number \(system\)|Hardware UUID|Provisioning UDID)\s*:"),
}
DENIED_SUFFIXES = {".sqlite", ".sqlite-wal", ".sqlite-shm", ".db", ".p12", ".p8", ".pem", ".key", ".dmg", ".zip", ".mp4", ".mov", ".amr"}

def main():
    # Tracked plus non-ignored files, so future accidental additions are checked.
    result = subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT, capture_output=True, check=True)
    paths = sorted(set(p for p in result.stdout.decode().split("\0") if p))
    failures = []
    for name in paths:
        path = ROOT / name
        relative = Path(name)
        if relative.parts[0] not in ALLOWED_DIRS and name not in ALLOWED_FILES:
            failures.append((name, "outside public allowlist"))
        if path.is_symlink():
            failures.append((name, "symlink requires review")); continue
        if path.suffix.lower() in DENIED_SUFFIXES or path.name.startswith(".env"):
            failures.append((name, "sensitive or release-only file type"))
        if not path.is_file():
            continue
        data = path.read_bytes()
        if b"\0" in data[:8192]:
            if relative.parts[0] != "Resources" or path.suffix.lower() not in {".png", ".icns"}:
                failures.append((name, "unreviewed binary"))
            continue
        text = data.decode("utf-8", errors="replace")
        for label, regex in RULES.items():
            if regex.search(text):
                failures.append((name, label))
    if failures:
        for name, reason in failures:
            print(f"FAIL {name}: {reason}")
        return 1
    print(f"PASS: {len(paths)} public source files; no configured sensitive patterns detected.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
