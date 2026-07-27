#!/usr/bin/env python3
"""Print the spec's own info.version (the producer's version), or nothing.

Used by mirror.sh so registry version tags carry the API owner's real versioning
scheme (e.g. Stripe's date tags, Adyen's service majors) instead of a synthetic
counter. Handles JSON and YAML; any parse problem prints nothing — the caller
falls back to a date tag.
"""
import json
import re
import sys

path = sys.argv[1]
raw = open(path, "r", encoding="utf-8", errors="replace").read()

version = None
try:
    version = json.loads(raw).get("info", {}).get("version")
except Exception:
    try:
        import yaml  # available on GitHub runners; optional locally

        version = (yaml.safe_load(raw) or {}).get("info", {}).get("version")
    except Exception:
        # last resort: first `version:` line inside the info block
        m = re.search(r"^info:.*?^\s{2,}version:\s*['\"]?([^'\"\n]+)", raw, re.S | re.M)
        version = m.group(1).strip() if m else None

if version:
    # keep tags URL- and column-safe: printable, <=100 chars, no whitespace
    v = str(version).strip().replace(" ", "-")[:100]
    if v:
        print(v)
