#!/usr/bin/env python3
"""Normalise one CONTRACT.md payload so it can be compared to a golden.

    normalise.py PAYLOAD [ROOT]

Prints the payload as canonical JSON (sorted keys, two-space indent). Exactly
four things are normalised, and each one is normalised because it cannot be
made a function of the fixture:

  generated_at   RFC 3339 wall clock. ENGINEERING-PLAYBOOK.md §7 keeps
                 timestamps out of equality-critical comparisons.
  mole_version   diagnostic only (CONTRACT.md §1.5), and it changes at every
                 release. Pinning it would turn a version bump into eight
                 golden failures, which trains people to regenerate in bulk.
  ROOT           the throwaway HOME or fixture directory, which is a fresh
                 mktemp path on every run and a different path on every
                 machine. Replaced with the literal {ROOT}.
  plan_digest    sha256 over the absolute paths above, so it varies with ROOT
                 by construction. It is NOT simply dropped: tests/
                 contract_goldens.bats recomputes it independently from §7.2's
                 canonical serialisation and compares against the emitted
                 value, which is a stronger check than freezing a hex string.

Entry ids are sha256(path) truncated to 16 hex chars (§7.3), so they vary with
ROOT too. They are recomputed over the NORMALISED path rather than blanked, so
the golden still pins that every id is that pure function of its own path, that
ids are distinct, and that `selected` and `results` refer to the same entries.

Everything else -- every byte count, every flag, every label, every category,
every outcome, every ordering -- is compared literally.
"""

import hashlib
import json
import sys

NORMALISED_SCALARS = {
    "generated_at": "{GENERATED_AT}",
    "mole_version": "{MOLE_VERSION}",
    "plan_digest": "{DIGEST}",
}


def normalise_path(value, root):
    if root and isinstance(value, str):
        return value.replace(root, "{ROOT}")
    return value


def entry_id(path):
    return hashlib.sha256(path.encode("utf-8")).hexdigest()[:16]


def collect_id_map(node, root, mapping):
    """Every dict carrying both an id and a path defines one id remapping."""
    if isinstance(node, dict):
        if isinstance(node.get("id"), str) and isinstance(node.get("path"), str):
            mapping[node["id"]] = entry_id(normalise_path(node["path"], root))
        for value in node.values():
            collect_id_map(value, root, mapping)
    elif isinstance(node, list):
        for item in node:
            collect_id_map(item, root, mapping)


def walk(node, root, mapping, key=None):
    if isinstance(node, dict):
        return {k: walk(v, root, mapping, k) for k, v in node.items()}
    if isinstance(node, list):
        return [walk(v, root, mapping, key) for v in node]
    if isinstance(node, str):
        if key in NORMALISED_SCALARS:
            return NORMALISED_SCALARS[key]
        if node in mapping:
            return mapping[node]
        return normalise_path(node, root)
    return node


def main(argv):
    if len(argv) not in (2, 3):
        sys.stderr.write(__doc__)
        return 2
    payload = json.load(open(argv[1], encoding="utf-8"))
    root = argv[2] if len(argv) == 3 else ""
    mapping = {}
    collect_id_map(payload, root, mapping)
    print(json.dumps(walk(payload, root, mapping), sort_keys=True, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
