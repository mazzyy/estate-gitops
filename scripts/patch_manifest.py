#!/usr/bin/env python3
"""Targeted edits to the deployment manifest.

Regex on specific lines rather than a YAML round-trip, because loading and
re-dumping would reformat the file, strip the comments, and reorder the keys —
producing a diff full of noise that buries the one-character change the whole
demo is about. The Remediator's pull request should be readable at a glance.

    python3 scripts/patch_manifest.py bad-config
    python3 scripts/patch_manifest.py oom
    python3 scripts/patch_manifest.py restore
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

MANIFEST = Path(__file__).resolve().parent.parent / "apps" / "checkout-svc" / "deployment.yaml"

GOOD_ENDPOINT = "https://payments.internal/v2"
BAD_ENDPOINT = "htps://payments.internal/v2"  # one missing character


def _set_env(text: str, name: str, value: str) -> str:
    """Replace the `value:` on the line following `- name: <NAME>`."""
    pattern = re.compile(
        rf'(- name: {re.escape(name)}\s*\n(?:\s*#[^\n]*\n)*\s+value: )"[^"]*"'
    )
    new, count = pattern.subn(rf'\g<1>"{value}"', text)
    if count != 1:
        raise SystemExit(f"expected exactly 1 match for env {name}, found {count}")
    return new


def _set_memory_limit(text: str, value: str) -> str:
    """Only the limit under `limits:`, never the one under `requests:`."""
    pattern = re.compile(r"(limits:\s*\n\s+cpu: [^\n]*\n(?:\s*#[^\n]*\n)*\s+memory: )\S+")
    new, count = pattern.subn(rf"\g<1>{value}", text)
    if count != 1:
        raise SystemExit(f"expected exactly 1 memory limit, found {count}")
    return new


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    text = MANIFEST.read_text()

    if mode == "bad-config":
        text = _set_env(text, "PAYMENT_ENDPOINT", BAD_ENDPOINT)
    elif mode == "oom":
        text = _set_env(text, "WARMUP_MB", "128")
        text = _set_memory_limit(text, "64Mi")
    elif mode == "restore":
        text = _set_env(text, "PAYMENT_ENDPOINT", GOOD_ENDPOINT)
        text = _set_env(text, "WARMUP_MB", "8")
        text = _set_memory_limit(text, "256Mi")
    else:
        print(__doc__)
        return 2

    MANIFEST.write_text(text)
    print(f"  patched {MANIFEST.name}: {mode}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
