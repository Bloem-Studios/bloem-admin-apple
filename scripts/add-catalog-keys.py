#!/usr/bin/env python3
"""Appends missing keys to BloemAdmin/Localizable.xcstrings without reordering or rewriting the file.

Usage: scripts/add-catalog-keys.py KEY [KEY ...]   (or keys on stdin, one per line, with no arguments)
"""
import json
import pathlib
import sys

catalog = pathlib.Path(__file__).resolve().parent.parent / "BloemAdmin" / "Localizable.xcstrings"
text = catalog.read_text()
existing = set(json.loads(text)["strings"].keys())
keys = sys.argv[1:] or [line.rstrip("\n") for line in sys.stdin if line.strip()]
new = [k for k in dict.fromkeys(keys) if k not in existing]
if not new:
    print("nothing to add")
    sys.exit(0)
tail = '\n  },\n  "version" : "1.0"\n}\n'
assert text.endswith(tail), "unexpected catalog layout"
body = text[: -len(tail)]
# body ends with the last entry's closing brace "    }"
for key in new:
    body += ',\n    ' + json.dumps(key, ensure_ascii=False) + ' : {\n\n    }'
catalog.write_text(body + tail)
json.loads(catalog.read_text())
print(f"added {len(new)} keys")
