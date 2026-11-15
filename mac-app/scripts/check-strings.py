#!/usr/bin/env python3
"""Checks the Mac app's user-visible strings.

  python3 -I scripts/check-strings.py

1. Every localizable English literal in Sources/ATA (Text/Button/Label/Toggle/Section/Menu titles and
   String(localized:)) has a zh-Hant translation, and no translation is orphaned. Interpolations become %lld for the
   integer expressions listed in INT_EXPRS and %@ otherwise; a literal % becomes %%.
2. No user-visible text (English sources, zh-Hant values, InfoPlist strings) uses a word from the glossary's
   "never show" list (internal TERMS.md), so jargon can't creep back in.
Exit status 1 on any problem.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = sorted((ROOT / "Sources" / "ATA").glob("*.swift"))
ZH = ROOT / "Resources" / "zh-Hant.lproj" / "Localizable.strings"
INFOPLISTS = [ROOT / "Resources" / "en.lproj" / "InfoPlist.strings", ROOT / "Resources" / "zh-Hant.lproj" / "InfoPlist.strings"]

# Interpolated expressions that are integers (→ %lld). Everything else is a string (→ %@).
INT_EXPRS = {"left / 60", "pct", "n", "n - 3", "s.failedFiles"}

# TERMS.md "Words we never show to users" (the ones that could plausibly appear in this app). Matched case-insensitively
# as whole words for Latin text, as substrings for Chinese.
NEVER_LATIN = ["LAN", "P2P", "peer-to-peer", "direct path", "STUN", "TURN", "relay", "WebRTC", "ICE", "TCP", "port",
               "IP address", "Bluetooth LE", "BLE", "GATT", "handshake", "HMAC", "AES", "GCM", "DTLS", "session",
               "protocol", "checksum", "SHA-256", "verification", "signature", "certificate", "fingerprint",
               "notarize", "Gatekeeper", "quarantine", "codesign", "universal", "Apple silicon", "arm64", "sudo",
               "CLI", "repo", "open source", "Keychain", "ata://", "unexpected data", "identity", "decrypt",
               "local network", "error:", "QR 碼"]
NEVER_ZH = ["區網", "點對點", "直連", "轉送伺服器", "連接埠", "藍牙低功耗", "握手", "端對端加密", "協定", "校驗碼",
            "驗證失敗", "簽章", "憑證", "指紋", "公證", "通用版本", "Apple 晶片", "QR 碼", "區域網路", "錯誤："]

PREFIX = re.compile(r'(?:\b(?:Text|Button|Label|Toggle|Section|Menu)\(|String\(localized: )"')
# Button(cond ? "A" : "B") — both literals are localized keys.
TERNARY = re.compile(r'\bButton\([^"\n]*\? "([^"]*)" : "([^"]*)"\)')


def literals(text: str):
    """Yields the bodies of string literals that follow a UI call prefix. Interpolations may contain nested quotes
    and parentheses, so this scans instead of using one regex."""
    for m in PREFIX.finditer(text):
        i, out = m.end(), []
        while i < len(text):
            c = text[i]
            if text.startswith("\\(", i):
                depth, j = 1, i + 2
                while depth and j < len(text):
                    if text[j] == '"':            # skip a nested string literal inside the interpolation
                        j = text.index('"', j + 1) + 1
                        continue
                    depth += {"(": 1, ")": -1}.get(text[j], 0)
                    j += 1
                out.append(text[i:j]); i = j
            elif c == "\\":
                out.append(text[i:i + 2]); i += 2
            elif c == '"' or c == "\n":
                break
            else:
                out.append(c); i += 1
        yield "".join(out)


def key_of(lit: str) -> str:
    out, i = [], 0
    while i < len(lit):
        if lit.startswith("\\(", i):
            depth, j = 1, i + 2
            while depth:
                if lit[j] == '"':
                    j = lit.index('"', j + 1) + 1
                    continue
                depth += {"(": 1, ")": -1}.get(lit[j], 0)
                j += 1
            expr = lit[i + 2:j - 1]
            out.append("%lld" if expr in INT_EXPRS else "%@")
            i = j
        elif lit[i] == "%":
            out.append("%%"); i += 1
        elif lit.startswith('\\"', i):
            out.append('"'); i += 2
        else:
            out.append(lit[i]); i += 1
    return "".join(out)


def source_keys():
    keys = set()
    for f in SRC:
        text = f.read_text()
        for m in TERNARY.finditer(text):
            keys.update(m.groups())
        for lit in literals(text):
            # Skip non-UI literals the pattern can catch (identifiers, URLs, SF Symbol names, log text).
            if not lit or lit.startswith(("http", "x-apple", "io.github")) or "." in lit and " " not in lit:
                continue
            if re.fullmatch(r"[a-z0-9_.]+", lit):
                continue
            keys.add(key_of(lit))
    return keys


def zh_table():
    d = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(ZH)]))
    return d


def jargon(text: str):
    hits = []
    for w in NEVER_LATIN:
        # Acronyms (LAN, TURN, ICE, …) only as acronyms; "turn on" and "ice" are fine.
        flags = 0 if w.isupper() else re.IGNORECASE
        if re.search(r"(?<![A-Za-z])" + re.escape(w) + r"(?![A-Za-z])", text, flags):
            hits.append(w)
    hits += [w for w in NEVER_ZH if w in text]
    return hits


def main() -> int:
    problems = 0
    keys = source_keys()
    zh = zh_table()
    # Strings that are intentionally the same in both languages or not UI (product name, log tags).
    ignore = {"ATA"}
    missing = sorted(k for k in keys - set(zh) - ignore)
    orphaned = sorted(k for k in set(zh) - keys)
    for k in missing:
        print(f"missing zh-Hant translation: {k!r}"); problems += 1
    for k in orphaned:
        print(f"zh-Hant entry not used by the app: {k!r}"); problems += 1
    for k, v in zh.items():
        for bad, where in ((jargon(k), "English"), (jargon(v), "zh-Hant")):
            for w in bad:
                print(f"never-show word {w!r} in {where} text: {(k if where == 'English' else v)!r}"); problems += 1
    for f in INFOPLISTS:
        d = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(f)]))
        for k, v in d.items():
            if k == "NSHumanReadableCopyright":
                continue   # TERMS.md: the licence name may stay in the About box
            for w in jargon(v):
                print(f"never-show word {w!r} in {f.parent.name}/{f.name} {k}"); problems += 1
    print(f"{len(keys)} localizable strings, {len(zh)} zh-Hant entries, {problems} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
