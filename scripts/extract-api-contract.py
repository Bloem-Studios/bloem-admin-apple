#!/usr/bin/env python3 -I
"""Writes BloemAdminTests/Resources/api-contract.json from the two v2 OpenAPI documents.

For every path and method it records the declared query parameter names, the declared
numeric bounds of each query parameter ("query_bounds": name -> {"min", "max"}, only the
bounds its schema declares), whether a request body is required, and the declared success
statuses. APIContractTests checks every request the app can make against this file.

Regenerate (stdlib only): save the Silo server's v2 OpenAPI document and the Bloem server's as silo_v2.json and
bloem_v2.json, then:

    python3 -I scripts/extract-api-contract.py silo_v2.json bloem_v2.json \
        BloemAdminTests/Resources/api-contract.json

Both documents list full paths (for example /api/v2/admin/tasks and /api/bloem/v2/admin/...).
"""
import json
import sys

METHODS = ("get", "post", "put", "patch", "delete")


def bounds(params):
    """name -> {"min": n, "max": n} for query parameters whose schema declares either bound."""
    out = {}
    for p in params:
        if p.get("in") != "query":
            continue
        schema = p.get("schema") or {}
        found = {}
        if "minimum" in schema:
            found["min"] = schema["minimum"]
        if "maximum" in schema:
            found["max"] = schema["maximum"]
        if found:
            out[p["name"]] = found
    return out


def extract(document):
    out = {}
    for path, item in document["paths"].items():
        shared = item.get("parameters", [])
        for method in METHODS:
            op = item.get(method)
            if op is None:
                continue
            params = list(shared) + list(op.get("parameters", []))
            body = op.get("requestBody") or {}
            out.setdefault(path, {})[method] = {
                "query": sorted({p["name"] for p in params if p.get("in") == "query"}),
                "query_bounds": bounds(params),
                "required_query": sorted({p["name"] for p in params if p.get("in") == "query" and p.get("required")}),
                "body_required": bool(body.get("required")),
                "success": sorted(s for s in op.get("responses", {}) if s.startswith("2")),
            }
    return out


def main(argv):
    if len(argv) != 4:
        sys.exit("usage: extract-api-contract.py SILO.json BLOEM.json OUT.json")
    contract = {}
    for source in argv[1:3]:
        with open(source) as handle:
            contract.update(extract(json.load(handle)))
    with open(argv[3], "w") as handle:
        json.dump(contract, handle, indent=1, sort_keys=True)
        handle.write("\n")


main(sys.argv)
