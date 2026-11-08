#!/usr/bin/env python3
"""Extract engine-agnostic data from the legacy APEX VELOCITY three.js project.

The legacy game keeps most of its content in plain JS literals:
  - src/cars/roster.js   CAR_SPECS / PAINT_PALETTES / ENGINE_FOR
  - src/tracks.js        TRACKS (8 GP circuits)
  - src/garage.js        cosmetic + upgrade tables
  - src/main.js          AI_DEFS / RIVAL_OFFSETS
  - src/records.js       MEDAL_INFO / PACE

This script slices each literal out of the source text with a bracket matcher
and parses it with a small JavaScript-object-literal parser, so the result is
faithful JSON that any engine (Godot/Unity/UE) can consume.

Usage:
  python3 tools/extract_legacy_data.py [--legacy PATH] [--out PATH]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

DEFAULT_LEGACY = Path("/Users/tong/Desktop/windows电脑备份/赛车游戏/赛车游戏")
DEFAULT_OUT = Path("/Users/tong/Desktop/极速巅峰/data")


class JSLiteralError(RuntimeError):
    pass


class JSParser:
    """Tiny parser for JSON-ish JS literals (objects/arrays/strings/numbers)."""

    def __init__(self, text: str):
        self.s = text
        self.i = 0

    # -- helpers ---------------------------------------------------------
    def _skip_ws_comments(self) -> None:
        s, n = self.s, len(self.s)
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n\ufeff":
                self.i += 1
            elif s.startswith("//", self.i):
                j = s.find("\n", self.i)
                self.i = n if j < 0 else j + 1
            elif s.startswith("/*", self.i):
                j = s.find("*/", self.i + 2)
                if j < 0:
                    raise JSLiteralError("unterminated block comment")
                self.i = j + 2
            else:
                break

    def _peek(self) -> str:
        self._skip_ws_comments()
        return self.s[self.i] if self.i < len(self.s) else ""

    def parse(self):
        self._skip_ws_comments()
        value = self._value()
        self._skip_ws_comments()
        if self.i != len(self.s):
            raise JSLiteralError(f"trailing content at offset {self.i}: {self.s[self.i:self.i+40]!r}")
        return value

    # -- grammar ---------------------------------------------------------
    def _value(self):
        c = self._peek()
        if c == "{":
            return self._object()
        if c == "[":
            return self._array()
        if c in "'\"`":
            return self._string()
        if c == "-" or c.isdigit():
            return self._number()
        ident = self._identifier()
        if ident == "true":
            return True
        if ident == "false":
            return False
        if ident == "null":
            return None
        raise JSLiteralError(f"unsupported token {ident!r} at offset {self.i}")

    def _object(self) -> dict:
        self.i += 1  # {
        out: dict = {}
        while True:
            c = self._peek()
            if c == "}":
                self.i += 1
                return out
            if c == "":
                raise JSLiteralError("unterminated object")
            key = self._key()
            c = self._peek()
            if c != ":":
                raise JSLiteralError(f"expected ':' after key {key!r} at {self.i}")
            self.i += 1
            out[key] = self._value()
            c = self._peek()
            if c == ",":
                self.i += 1
            elif c == "}":
                continue
            else:
                raise JSLiteralError(f"expected ',' or '}}' at {self.i}")

    def _key(self) -> str:
        c = self._peek()
        if c in "'\"":
            return self._string()
        if c.isdigit():
            return str(self._number())
        m = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*").match(self.s, self.i)
        if not m:
            raise JSLiteralError(f"bad object key at {self.i}")
        self.i = m.end()
        return m.group(0)

    def _array(self) -> list:
        self.i += 1  # [
        out: list = []
        while True:
            c = self._peek()
            if c == "]":
                self.i += 1
                return out
            if c == "":
                raise JSLiteralError("unterminated array")
            out.append(self._value())
            c = self._peek()
            if c == ",":
                self.i += 1
            elif c == "]":
                continue
            else:
                raise JSLiteralError(f"expected ',' or ']' at {self.i}")

    def _string(self) -> str:
        quote = self.s[self.i]
        self.i += 1
        out: list[str] = []
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c == "\\":
                self.i += 1
                esc = s[self.i] if self.i < len(s) else ""
                mapping = {
                    "n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f",
                    "v": "\v", "0": "\0", "\\": "\\", "'": "'", '"': '"', "`": "`",
                    "/": "/", "\n": "",
                }
                if esc in mapping:
                    out.append(mapping[esc])
                    self.i += 1
                elif esc == "u":
                    hexs = s[self.i + 1:self.i + 5]
                    if len(hexs) == 4 and re.fullmatch(r"[0-9a-fA-F]{4}", hexs):
                        out.append(chr(int(hexs, 16)))
                        self.i += 5
                    else:
                        raise JSLiteralError(f"bad \\u escape at {self.i}")
                elif esc == "x":
                    hexs = s[self.i + 1:self.i + 3]
                    if len(hexs) == 2 and re.fullmatch(r"[0-9a-fA-F]{2}", hexs):
                        out.append(chr(int(hexs, 16)))
                        self.i += 3
                    else:
                        raise JSLiteralError(f"bad \\x escape at {self.i}")
                else:
                    out.append(esc)
                    self.i += 1
            else:
                if quote == "`" and s.startswith("${", self.i):
                    raise JSLiteralError("template interpolation unsupported")
                out.append(c)
                self.i += 1
        raise JSLiteralError("unterminated string")

    def _number(self):
        m = re.compile(r"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)").match(self.s, self.i)
        if not m:
            raise JSLiteralError(f"bad number at {self.i}")
        raw = m.group(0)
        self.i = m.end()
        if raw.lower().startswith(("0x", "-0x")):
            return int(raw, 16)
        if re.fullmatch(r"-?\d+", raw):
            return int(raw)
        return float(raw)

    def _identifier(self) -> str:
        m = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*").match(self.s, self.i)
        if not m:
            raise JSLiteralError(f"expected value at {self.i}")
        self.i = m.end()
        return m.group(0)


def find_literal(text: str, decl: str, opener: str) -> str:
    """Return the literal text that starts at the first `opener` after `decl`."""
    pos = text.find(decl)
    if pos < 0:
        raise JSLiteralError(f"declaration not found: {decl}")
    start = text.find(opener, pos)
    if start < 0:
        raise JSLiteralError(f"opener {opener!r} not found after {decl}")
    close = {"[": "]", "{": "}"}[opener]
    depth = 0
    i = start
    n = len(text)
    while i < n:
        c = text[i]
        if c in "'\"`":
            quote = c
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    break
                i += 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        elif c == opener:
            depth += 1
        elif c == close:
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    raise JSLiteralError(f"unbalanced literal after {decl}")


def extract(src: Path, decl: str, opener: str):
    text = src.read_text(encoding="utf-8")
    literal = find_literal(text, decl, opener)
    try:
        return JSParser(literal).parse()
    except JSLiteralError as exc:
        raise JSLiteralError(f"{src.name} :: {decl}: {exc}") from exc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--legacy", type=Path, default=DEFAULT_LEGACY)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args()
    legacy, out = args.legacy, args.out
    if not (legacy / "src").is_dir():
        print(f"legacy project not found: {legacy}", file=sys.stderr)
        return 2
    out.mkdir(parents=True, exist_ok=True)

    src = legacy / "src"
    report: dict = {"legacy_root": str(legacy), "outputs": {}}

    def dump(name: str, payload) -> None:
        path = out / name
        path.write_text(json.dumps(payload, ensure_ascii=False, indent=1), encoding="utf-8")
        report["outputs"][name] = path.stat().st_size
        print(f"  {name:<22} {path.stat().st_size:>10,} B")

    print("Extracting APEX VELOCITY legacy data ...")

    cars_specs = extract(src / "cars/roster.js", "CAR_SPECS", "[")
    palettes = extract(src / "cars/roster.js", "PAINT_PALETTES", "{")
    engine_for = extract(src / "cars/roster.js", "ENGINE_FOR", "{")
    dump("cars.json", {
        "source": "src/cars/roster.js",
        "count": len(cars_specs),
        "specs": cars_specs,
        "palettes": palettes,
        "engine_for": engine_for,
    })

    tracks = extract(src / "tracks.js", "TRACKS", "[")
    dump("tracks.json", {"source": "src/tracks.js", "count": len(tracks), "tracks": tracks})

    garage = {
        "source": "src/garage.js",
        "wheel_styles": extract(src / "garage.js", "WHEEL_STYLES", "["),
        "tire_styles": extract(src / "garage.js", "TIRE_STYLES", "["),
        "rim_finishes": extract(src / "garage.js", "RIM_FINISHES", "["),
        "calipers": extract(src / "garage.js", "CALIPERS", "["),
        "wing_styles": extract(src / "garage.js", "WING_STYLES", "["),
        "liveries": extract(src / "garage.js", "LIVERIES", "["),
        "upgrades": extract(src / "garage.js", "UPGRADES", "{"),
        "upgrade_keys": extract(src / "garage.js", "UPGRADE_KEYS", "["),
    }
    dump("garage.json", garage)

    ai_defs = extract(src / "main.js", "const AI_DEFS", "[")
    rival_offsets = extract(src / "main.js", "const RIVAL_OFFSETS", "[")
    camera_modes = extract(src / "main.js", "const CAMERA_MODES", "[")
    dump("ai.json", {
        "source": "src/main.js",
        "defs": ai_defs,
        "rival_offsets": rival_offsets,
        "camera_modes": camera_modes,
    })

    records = {
        "source": "src/records.js",
        "medal_info": extract(src / "records.js", "MEDAL_INFO", "{"),
        "pace": extract(src / "records.js", "const PACE", "{"),
    }
    dump("records.json", records)

    # JSON assets are copied verbatim
    manifest = json.loads((legacy / "assets/cars/models/manifest.json").read_text(encoding="utf-8"))
    dump("car_manifest.json", manifest)
    bgm_manifest = json.loads((legacy / "audio/bgm/manifest.json").read_text(encoding="utf-8"))
    dump("bgm_manifest.json", bgm_manifest)

    # Sanity checks
    ids = [s["id"] for s in cars_specs]
    manifest_ids = list(manifest["cars"].keys())
    track_ids = [t["id"] for t in tracks]
    errors = []
    if len(ids) != len(set(ids)):
        errors.append("duplicate car ids in CAR_SPECS")
    if set(ids) != set(manifest_ids):
        errors.append(f"CAR_SPECS vs manifest mismatch: only_specs={sorted(set(ids)-set(manifest_ids))} only_manifest={sorted(set(manifest_ids)-set(ids))}")
    if set(palettes) - set(ids):
        errors.append(f"palettes reference unknown cars: {sorted(set(palettes)-set(ids))}")
    if set(engine_for) - set(ids):
        errors.append(f"engine_for references unknown cars: {sorted(set(engine_for)-set(ids))}")
    report["checks"] = {
        "cars": len(ids),
        "palettes": len(palettes),
        "engine_profiles": len(engine_for),
        "tracks": len(track_ids),
        "track_ids": track_ids,
        "ai": len(ai_defs),
        "parts_style_tables": {k: len(garage[k]) for k in ("wheel_styles", "tire_styles", "rim_finishes", "calipers", "wing_styles", "liveries")},
        "errors": errors,
    }
    (out / "_extraction_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print("\nChecks:")
    print(f"  cars            : {len(ids)}")
    print(f"  paint palettes  : {len(palettes)}")
    print(f"  engine profiles : {len(engine_for)}")
    print(f"  tracks          : {len(track_ids)} -> {', '.join(track_ids)}")
    print(f"  ai rivals       : {len(ai_defs)}")
    if errors:
        print("\n  !! ERRORS:")
        for err in errors:
            print(f"     - {err}")
        return 1
    print("\n  all cross-checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
