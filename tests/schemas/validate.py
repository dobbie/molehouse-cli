#!/usr/bin/env python3
"""Validate a JSON payload against one of tests/schemas/*.schema.json.

CONTRACT.md is prose. This turns it into something a test can fail on.

Usage:
    validate.py SCHEMA PAYLOAD          # payload is a JSON document
    validate.py --ndjson SCHEMA PAYLOAD # payload is newline-delimited JSON,
                                        # one document per line (CONTRACT.md §3)

Every violation is printed, one per line, as `<json pointer>: <reason>`.
Exit 0 when the payload satisfies the schema, 1 when it does not, 2 on a usage
or schema-loading error.

Stdlib only, deliberately: `jsonschema` is not installed on this machine and
ENGINEERING-PLAYBOOK.md §4 makes adding a dependency a decision, not a
convenience. Only the keyword subset the schemas actually use is implemented,
and an unknown keyword is an error rather than a silent no-op -- a validator
that quietly ignores half a schema is the "test that cannot fail" archetype
this file exists to prevent.

Supported keywords:
    $ref (whole-subschema, sibling file only), allOf, type, enum, const,
    required, properties, additionalProperties, items, minItems, minimum,
    maximum, pattern, description/title/$schema/$comment (annotations,
    ignored).
"""

import json
import os
import re
import sys

ANNOTATIONS = {"description", "title", "$schema", "$comment", "examples"}

SUPPORTED = ANNOTATIONS | {
    "$ref",
    "allOf",
    "type",
    "enum",
    "const",
    "required",
    "properties",
    "additionalProperties",
    "items",
    "minItems",
    "minimum",
    "maximum",
    "pattern",
}


class SchemaError(Exception):
    """The schema document itself is wrong. Never a payload verdict."""


def _type_name(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _matches_type(value, wanted):
    # bool is a subclass of int in Python. A payload that says "true" where the
    # contract says a byte count -- or 1 where it says a flag -- must be
    # rejected, so the bool check comes first everywhere.
    if wanted == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if wanted == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if wanted == "boolean":
        return isinstance(value, bool)
    if wanted == "string":
        return isinstance(value, str)
    if wanted == "array":
        return isinstance(value, list)
    if wanted == "object":
        return isinstance(value, dict)
    if wanted == "null":
        return value is None
    raise SchemaError("unknown type name: %r" % (wanted,))


class Validator:
    def __init__(self, schema, base_dir):
        self.base_dir = base_dir
        self.root = schema
        self.errors = []

    def _err(self, pointer, reason):
        self.errors.append("%s: %s" % (pointer or "<root>", reason))

    def _resolve(self, schema, pointer):
        """A `$ref` names a sibling schema file and replaces the subschema."""
        ref = schema["$ref"]
        if len(schema) > 1 and set(schema) - {"$ref"} - ANNOTATIONS:
            raise SchemaError("$ref must not carry sibling keywords: %r" % (schema,))
        if "/" in ref or not ref.endswith(".schema.json"):
            raise SchemaError("$ref must name a sibling *.schema.json file: %r" % (ref,))
        path = os.path.join(self.base_dir, ref)
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)

    def validate(self, value, schema=None, pointer=""):
        schema = self.root if schema is None else schema
        if not isinstance(schema, dict):
            raise SchemaError("subschema at %s is not an object" % (pointer or "<root>"))

        unknown = set(schema) - SUPPORTED
        if unknown:
            raise SchemaError(
                "unsupported keyword(s) %s at %s" % (sorted(unknown), pointer or "<root>")
            )

        if "$ref" in schema:
            return self.validate(value, self._resolve(schema, pointer), pointer)

        # allOf is how the five envelope payloads share CONTRACT.md §1.5
        # without five copies of it: one branch is the envelope, the next
        # constrains this command's `command`, `mode` and `data`.
        for branch in schema.get("allOf", []):
            self.validate(value, branch, pointer)

        if "type" in schema:
            wanted = schema["type"]
            wanted = wanted if isinstance(wanted, list) else [wanted]
            if not any(_matches_type(value, name) for name in wanted):
                self._err(
                    pointer,
                    "expected %s, got %s (%r)" % ("|".join(wanted), _type_name(value), value),
                )
                # Every keyword below assumes the type held. Stop here rather
                # than emit a cascade of confusing follow-on errors.
                return self.errors

        if "enum" in schema and value not in schema["enum"]:
            self._err(pointer, "value %r is not one of %r" % (value, schema["enum"]))
        if "const" in schema and value != schema["const"]:
            self._err(pointer, "value %r is not %r" % (value, schema["const"]))
        if "pattern" in schema and isinstance(value, str):
            if not re.search(schema["pattern"], value):
                self._err(pointer, "value %r does not match /%s/" % (value, schema["pattern"]))
        if "minimum" in schema and isinstance(value, (int, float)) and not isinstance(value, bool):
            if value < schema["minimum"]:
                self._err(pointer, "value %r is below minimum %r" % (value, schema["minimum"]))
        if "maximum" in schema and isinstance(value, (int, float)) and not isinstance(value, bool):
            if value > schema["maximum"]:
                self._err(pointer, "value %r is above maximum %r" % (value, schema["maximum"]))

        if isinstance(value, dict):
            self._validate_object(value, schema, pointer)
        elif isinstance(value, list):
            self._validate_array(value, schema, pointer)

        return self.errors

    def _validate_object(self, value, schema, pointer):
        for name in schema.get("required", []):
            if name not in value:
                self._err(pointer, "missing required property %r" % (name,))
        properties = schema.get("properties", {})
        for name, subschema in properties.items():
            if name in value:
                self.validate(value[name], subschema, "%s/%s" % (pointer, name))
        extra = schema.get("additionalProperties", True)
        if extra is False:
            for name in value:
                if name not in properties:
                    self._err(pointer, "unexpected property %r" % (name,))
        elif isinstance(extra, dict):
            for name in value:
                if name not in properties:
                    self.validate(value[name], extra, "%s/%s" % (pointer, name))

    def _validate_array(self, value, schema, pointer):
        if "minItems" in schema and len(value) < schema["minItems"]:
            self._err(pointer, "has %d items, minimum %d" % (len(value), schema["minItems"]))
        if "items" in schema:
            for index, item in enumerate(value):
                self.validate(item, schema["items"], "%s/%d" % (pointer, index))


def validate_document(document, schema, base_dir):
    return Validator(schema, base_dir).validate(document)


def main(argv):
    args = list(argv[1:])
    ndjson = False
    if args and args[0] == "--ndjson":
        ndjson = True
        args.pop(0)
    if len(args) != 2:
        sys.stderr.write(__doc__)
        return 2
    schema_path, payload_path = args
    try:
        with open(schema_path, encoding="utf-8") as handle:
            schema = json.load(handle)
    except (OSError, ValueError) as exc:
        sys.stderr.write("cannot load schema %s: %s\n" % (schema_path, exc))
        return 2
    base_dir = os.path.dirname(os.path.abspath(schema_path))

    try:
        with open(payload_path, encoding="utf-8") as handle:
            raw = handle.read()
    except OSError as exc:
        sys.stderr.write("cannot read payload %s: %s\n" % (payload_path, exc))
        return 2

    documents = []
    if ndjson:
        for index, line in enumerate(raw.splitlines()):
            if not line.strip():
                continue
            try:
                documents.append(("frame %d" % index, json.loads(line)))
            except ValueError as exc:
                print("frame %d: not valid JSON: %s" % (index, exc))
                return 1
        if not documents:
            print("<root>: no frames in %s" % (payload_path,))
            return 1
    else:
        try:
            documents.append(("", json.loads(raw)))
        except ValueError as exc:
            print("<root>: not valid JSON: %s" % (exc,))
            return 1

    failed = False
    for label, document in documents:
        try:
            errors = validate_document(document, schema, base_dir)
        except SchemaError as exc:
            sys.stderr.write("schema error: %s\n" % (exc,))
            return 2
        for error in errors:
            failed = True
            print("%s%s" % (label + " " if label else "", error))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
