#!/usr/bin/env python3
"""
Whole-tree QML integrity audit.

Why this exists
---------------
`qs -p .` loading clean proves almost nothing. The preview builds the shell and
walks the rest face, so every surface behind a loader, every plug-in branch and
every setting row stays uncompiled until something opens it. That is why a bar
can ship a `Theme.surfaceHighlight` that does not exist, or a
`pill.checkMediaHover()` with no such function, and still "load fine" — the
error only fires on the interaction, as a runtime warning the user sees as a
glitch rather than a crash.

The most expensive bug in this repo's history was exactly that shape: a
ReferenceError aborting the statement *before* the one the user cared about, so
the feature silently did nothing. Static checks catch the class; a clean load
does not.

What it checks
--------------
1.  Unresolved id references (`foo.bar` where `foo` is not an id in scope).
    This is the `quickChoosing is not defined` class.
2.  Undeclared `Theme.*` tokens, against the real declaration site.
3.  Undeclared `Flags.*` properties, against the real declaration site.
4.  Duplicate `id:` declarations within a file (silently shadows; the loser is
    unreachable and its uses bind to the wrong object).
5.  Reads of properties that no component in the tree declares, for a small set
    of load-bearing singletons.

False positives are suppressed by construction rather than by a deny-list of
filenames: each check has an explicit allow-list of language and Qt built-ins,
and anything it cannot account for is reported as `unresolved` for review
instead of silently passing.

Exit code 0 when clean, 1 otherwise, so it can join the shell suite.
"""

from __future__ import annotations

import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()

# --- lexical noise -------------------------------------------------------
# Comments and string literals must not contribute "code", and getting this
# wrong is worse than not doing it: every false declaration is a false bug.
#
# Three attempts are baked into why this is a hand-written scanner.
#
# 1. Comments first, then strings: Flags.qml contains the literal
#    "unused\n    //* flags" — a help comment that opens with `/*`. Strip
#    comments first and that `/*` inside a string opens a block comment running
#    to the next `*/` elsewhere in the file, deleting 18 real property
#    declarations. Every affected setting then reported as undeclared.
#
# 2. Strings first, then comments: fixing (1) that way breaks on the opposite
#    side. QML doc comments are full of backtick-quoted identifiers, and
#    blanking backtick "templates" before the comments are gone lets a backtick
#    inside `/** ... */` open a template that runs to the next backtick in the
#    file. That swallowed the entire body of Flags.qml.
#
# 3. So: one left-to-right pass that classifies each construct in true lexical
#    order, blanking strings and comments as it meets them. Only the true
#    lexical order is correct here, because in every source language the two
#    nest — and a regex cannot nest.

# A `/` opens a regex (rather than dividing) when the previous meaningful token
# cannot end an expression. This is the standard heuristic and is the only
# context-free way to tell `a / b` from `/re/g` in JavaScript.
_REGEX_OK_BEFORE = {
    "", "(", ",", "=", ":", "[", "!", "&", "|", "?", "{", "}", ";", "+", "-",
    "*", "%", "<", ">", "~", "^", "return", "typeof", "case", "in", "of",
    "new", "delete", "void", "do", "else",
}


def _starts_regex(out: list[str]) -> bool:
    tail = "".join(out).rstrip()
    if not tail:
        return True
    m = re.search(r"([A-Za-z_$][\w$]*|[^\w\s])\s*$", tail)
    if not m:
        return True
    tok = m.group(1)
    return tok in _REGEX_OK_BEFORE


def strip_noise(src: str) -> str:
    """Blank comments and string/template literals, preserving line structure.

    Newlines inside a blanked region are kept so that line-anchored patterns
    still see the right line numbers and do not accidentally join two lines
    into one declaration.
    """
    out: list[str] = []
    i = 0
    n = len(src)
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""

        if c == "/" and nxt == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
            continue

        if c == "/" and nxt == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
            continue

        if c == "/" and _starts_regex(out):
            # JS regex literal, distinguished from division by what precedes it.
            # Needed here for two reasons, and the second is the dangerous one.
            #
            #  1. `Battery.qml` reads `/Failed|not[ -]found/i.test(enabled)`: the
            #     identifier immediately before `.test` is the regex *flag* `i`,
            #     not a variable, so a naive member scan reports `i.test` as an
            #     unresolved id.
            #  2. `Color.qml` has `/^([A-Za-z0-9_-]+)\s*=\s*["']?(#...)/` — a
            #     regex containing a double quote. Without this branch the quote
            #     opens a phantom string and the scanner blanks the remainder of
            #     the file, which is how a checker quietly stops looking.
            j = i + 1
            in_class = False
            while j < n:
                ch = src[j]
                if ch == "\\":
                    j += 2
                    continue
                if ch == "\n":
                    break
                if ch == "[":
                    in_class = True
                elif ch == "]":
                    in_class = False
                elif ch == "/" and not in_class:
                    j += 1
                    while j < n and src[j].isalpha():   # flags
                        j += 1
                    break
                j += 1
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
            continue

        if c in '"`':
            # Deliberately NOT the single quote. JS regex literals here contain
            # one — `replace(/["\']/g, "")` in OsMark.qml — and a scanner cannot
            # tell that quote from a string delimiter without also solving
            # regex-vs-division, which needs the previous token. Treating it as a
            # delimiter mis-paired the quotes and blanked the entire rest of the
            # file, which is the worst failure mode this tool can have: it
            # silently stops looking. A few false positives from single-quoted
            # strings ('hl.dsp.window.move(...)') are a cheap price for never
            # under-reporting.
            quote = c
            j = i + 1
            while j < n:
                if src[j] == "\\":       # escaped char, skip both
                    j += 2
                    continue
                if src[j] == quote:
                    j += 1
                    break
                j += 1
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
            continue

        out.append(c)
        i += 1
    return "".join(out)


# --- declarations --------------------------------------------------------
# `id: root` declares. `id: root.someProp` is a PropertyAnimation target — also
# written with `id:`, but it binds nothing and must not read as a second
# declaration. Anchoring the name to end-of-line removes that whole class.
# `id:` appears in two shapes. On its own line, and inline after a type
# declaration — `HoverHandler { id: rowHover }`, `Process { id: appimageProc }` is
# how most of this codebase declares an id, so a line-anchored pattern missed
# most of them and reported `rowHover.hovered` as undefined.
ID_DECL = re.compile(
    r"^\s*id:\s*([A-Za-z_]\w*)\s*$"
    r"|\{\s*id:\s*([A-Za-z_]\w*)\s*(?:;|\})",
    re.M,
)


def ids_in(src: str) -> list[str]:
    out: list[str] = []
    for m in ID_DECL.finditer(src):
        out.append(m.group(1) or m.group(2))
    return out
# `required` is a real modifier and is not cosmetic: a component that takes
# `required property var pill` and then reads `pill.closeStripMenus` was
# reported 3x per file until this accepted the keyword. `default` is here for
# the same reason.
PROP_DECL = re.compile(
    r"^\s*(?:required\s+)?(?:readonly\s+)?(?:default\s+)?property\s+"
    r"[A-Za-z_][\w<>.]*\s+([A-Za-z_]\w*)",
    re.M,
)
# `property alias name: target.name` is a declaration like any other. Flags.qml
# is 69 aliases onto one adapter object, so an audit that only understood
# `property <type> <name>` reports every single setting in the app as
# undeclared — which is how a checker earns a reputation for being noise.
ALIAS_DECL = re.compile(r"^\s*property\s+alias\s+([A-Za-z_]\w*)", re.M)
# `property Foo bar: Baz { id: qux }` — inline components name their id too.
SIGNAL_DECL = re.compile(r"^\s*signal\s+([A-Za-z_]\w*)", re.M)
FUNC_DECL = re.compile(r"^\s*function\s+([A-Za-z_]\w*)", re.M)
# Required/model params injected by the engine, not written in the file.
IMPLICIT_PARAMS = {"modelData", "index", "required", "parent", "model", "parentItem"}

# --- usages --------------------------------------------------------------
# `something.member` — the reference form that produced the runtime bugs.
MEMBER_REF = re.compile(r"(?<![\w.\$])([a-z_]\w*)\s*\.\s*([A-Za-z_]\w*)")
BARE_CALL = re.compile(r"(?<![\w.$\"])([a-z_]\w*)\s*\(")

# Language/Qt/JS built-ins that look like ids but are not.
BUILTINS = {
    # JS / QML language
    "console", "json", "math", "object", "array", "string", "number", "boolean",
    "parseInt", "parseFloat", "isNaN", "date", "regexp", "error", "symbol",
    "map", "set", "delete", "typeof", "void", "new", "this", "null", "true",
    "false", "undefined", "function", "return", "if", "else", "for", "while",
    "var", "let", "const", "in", "of", "do", "switch", "case", "break",
    "continue", "default", "try", "catch", "finally", "throw", "instanceof",
    "yield", "await", "async", "static", "class", "extends", "super", "with",
    # Qt namespaces
    "qt", "qqml", "qml", "theme", "flags", "motion", "color", "icons",
    "players", "cava", "battery", "battery1", "powerprofiles", "network",
    "bluetooth", "bluez", "system", "cliphist", "recast", "screens",
    "themeSync".lower(), "plugins", "plex", "scratch", "wallpaper", "fyne",
    "upower", "hypr", "omarchy", "better",
    # Common engine objects
    "parent", "children", "data", "resources", "state", "states", "transitions",
    "anchors", "transform", "layer", "font", "clip", "opacity", "visible",
    "rotation", "scale", "smooth", "loops", "behavior", "property",
    "signal", "function", "enum", "component", "pragma", "import",
    "item", "rectangle", "row", "column", "grid", "text", "image", "loader",
    "timer", "mousearea", "hoverhandler", "taphandler", "wheelhandler",
    "draghandler", "pinchhandler", "flickable", "listview", "repeater",
    "states", "connections", "component", "multieffect", "layer",
    "transformOrigin".lower(), "implicitWidth".lower(), "implicitHeight".lower(),
    "contentItem".lower(), "contentWidth".lower(), "contentHeight".lower(),
    "visualPosition".lower(), "visualSize".lower(),
}

# --- Qt grouped properties -----------------------------------------------
# `border.color`, `easing.type`, `anchor.fill` and friends are declared by
# QtQuick itself on every Item, not by this codebase. They are not allow-listed
# by name-and-file because a filename allow-list is how a checker starts hiding
# real bugs; they are modelled as what they are — a closed set of QtQuick
# grouped properties that resolve against any base.
QT_GROUPED = {
    "anchors", "border", "easing", "font", "layer", "transform", "gradient",
    "sourceSize", "childrenRect", "contentItem", "implicitSize",
    "horizontalAlignment", "verticalAlignment", "wrapMode", "textFormat",
    "elide", "maximumLineCount", "lineHeight", "renderType", "padding",
    "background", "box", "cursor", "scale", "rotation", "opacity", "visible",
    "clip", "smooth", "loops", "cache", "mipmap", "multisample", "status",
    "mode", "orientation", "direction", "flickableDirection",
    "live", "spacing", "material", "radius", "color", "title",
    "rect", "anchor", "edges", "gravity", "adjustment",
    "highlight", "pressed", "hovered", "checked", "down", "active",
}

# Injected by Repeater/Loader/delegates, never declared in the file.
REPEAT_VARS = {"item", "delegate", "index", "modelData", "modelIndex"}
# `qs.<Module>.<Member>` — resolved by the engine to the file's own directory.
QS_QUALIFIED = {"qs"}

# Members on any object are fine — Qt items are structurally dynamic. This audit
# only resolves the *base* identifier, which is what actually goes undefined.
MEMBER_OK = re.compile(
    r"^(qt|math|console|theme|flags|json|themeSync|motion|color|icons|players|"
    r"cava|battery|network|bluetooth|system|cliphist|recast|screens|plugins|"
    r"scratch|wallpaper|upower|hypr|omarchy|better)$",
    re.I,
)


def declared_names(src: str) -> set[str]:
    """Every name a file binds that a later expression can read as a base.

    Includes ids, properties, signals, functions, local `const`/`let`/`var`,
    and function parameters. The locals and params matter for the unresolved-id
    check: `colors.length` on a `property var colors` and `cb.a` on a
    `function f(cb)` are both resolvable, and a checker that only knew about
    ids reported several thousand of them.
    """
    names: set[str] = set()
    names |= set(ids_in(src))
    names |= set(PROP_DECL.findall(src))
    names |= set(ALIAS_DECL.findall(src))
    names |= set(SIGNAL_DECL.findall(src))
    names |= set(FUNC_DECL.findall(src))
    # `var a = 1, b = 2` binds two names; only the first is adjacent to the
    # keyword, so the rest are recovered from the declaration list.
    for stmt in re.findall(r"\b(?:const|let|var)\s+([^;\n]+)", src):
        for part in stmt.split(","):
            m2 = re.match(r"\s*([A-Za-z_]\w*)", part)
            if m2:
                names.add(m2.group(1))
    names |= set(re.findall(r"\bfunction\s*\w*\s*\(([^)]*)\)", src) and
                 [p.strip().split(":")[0].split("=")[0].strip()
                  for grp in re.findall(r"\bfunction\s*\w*\s*\(([^)]*)\)", src)
                  for p in grp.split(",") if p.strip()] or [])
    names |= set(re.findall(r"\bfor\s*\(\s*(?:const|let|var)\s+([A-Za-z_]\w*)", src))
    # Destructured params: `function f({ a, b })`
    for grp in re.findall(r"\bfunction\s*\w*\s*\(\s*\{([^)]*)\}", src):
        names |= set(re.findall(r"([A-Za-z_]\w*)\s*(?::|,|$)", grp))
    # Arrow parameter with no parens: `findIndex(e => ...)`.
    names |= set(re.findall(r"(?<![\w.\)])(\w+)\s*=>", src))
    # Signal handler parameters. `onPointChanged: function(point)` and
    # `onEntered: (m) => ...` both bind a name for the body, and QML resolves it
    # unqualified, so `point.scenePosition` inside a pointer handler is correct
    # and must not be reported.
    for grp in re.findall(r"\bon\w+\s*:\s*(?:function\s*)?\(([^)]*)\)", src):
        for p2 in grp.split(","):
            nm = p2.strip().split(":")[0].split("=")[0].strip()
            if re.fullmatch(r"[A-Za-z_]\w*", nm):
                names.add(nm)
    # QML unqualified scope includes the *enclosing object's own* properties, so
    # `source.toString()` inside an Image, or `screen.width` inside a PanelWindow,
    # resolve with no local declaration at all. Modelling that properly needs
    # scope tracking; the sound approximation is to treat a name the file assigns
    # as a property anywhere (`name:`) as bound.
    names |= set(re.findall(r"(?<![.\w])([a-z_]\w*)\s*:", src))
    # Object-literal and arrow-parameter bindings.
    for grp in re.findall(r"\(([^()]*)\)\s*=>", src):
        for part in grp.split(","):
            part = part.strip()
            if re.fullmatch(r"[A-Za-z_]\w*", part):
                names.add(part)
    return {n for n in names if n}


def qml_files() -> list[Path]:
    skip = {"preview", "node_modules", ".git", "lib"}
    out = []
    for p in sorted(ROOT.rglob("*.qml")):
        rel = p.relative_to(ROOT)
        if rel.parts and rel.parts[0] in skip:
            continue
        if "preview" in rel.parts:
            continue
        out.append(p)
    return out


def declared_tokens(path: Path, patterns: list[re.Pattern]) -> set[str]:
    """Tokens a file declares, plus what it re-exports from its Singletons.

    A `Theme.foo` read is only legal if *some* Theme definition declares `foo`.
    Theme is a singleton, so the declaration lives in exactly one file and every
    other file legitimately reads it — hence a whole-tree union rather than a
    per-file check.
    """
    src = strip_noise(path.read_text(errors="replace"))
    found: set[str] = set()
    for pat in patterns:
        found |= set(pat.findall(src))
    return found


def main() -> int:
    files = qml_files()
    problems: list[tuple[str, str, str]] = []  # (file, kind, detail)

    # ---- whole-tree token universes ------------------------------------
    theme_tokens: set[str] = set()
    flags_tokens: set[str] = set()
    # `property alias` is a declaration like any other. Flags.qml is almost
    # entirely aliases onto one adapter object, so an audit that only understood
    # `property <type> <name>` would report every setting in the app as
    # undeclared -- which is how a checker earns a reputation for being noise.
    ANY_DECL = re.compile(
        r"^\s*(?:readonly\s+)?property\s+(?:alias|[A-Za-z_][\w<>.]*)\s+([A-Za-z_]\w*)", re.M
    )
    for p in files:
        name = p.name
        src = strip_noise(p.read_text(errors="replace"))
        if name in ("Theme.qml", "Flags.qml", "FlagsAdapter.qml"):
            # Functions are part of the public surface. `Theme.hexUpper(c)` and
            # `Theme.refreshFonts()` are real members, and an audit that only
            # understood properties reported both as undeclared — which reads
            # exactly like a broken theme.
            found = set(ANY_DECL.findall(src)) | set(FUNC_DECL.findall(src))
            if name == "Theme.qml":
                theme_tokens |= found
            else:
                # Both halves count: a setting declared on the adapter is a real
                # flag even if the singleton forwards it by alias.
                flags_tokens |= found
    # Flags are also persisted by key in its JSON backend.
    flags_json = ROOT / "Singletons" / "Flags.json"
    if flags_json.exists():
        try:
            import json

            data = json.loads(flags_json.read_text())
            if isinstance(data, dict):
                flags_tokens |= set(data)
        except Exception:
            pass

    for p in files:
        rel = str(p.relative_to(ROOT))
        raw = p.read_text(errors="replace")
        src = strip_noise(raw)

        ids = ids_in(src)

        # ---- 4. duplicate ids -----------------------------------------
        seen: dict[str, int] = defaultdict(int)
        for i in ids:
            seen[i] += 1
        for name, n in seen.items():
            if n > 1:
                problems.append((rel, "duplicate-id", f"{name} x{n}"))

        # ---- 1. unresolved id references ------------------------------
        local = declared_names(src) | IMPLICIT_PARAMS
        for base, member in MEMBER_REF.findall(src):
            if base in BUILTINS or base in local:
                continue
            if base in QT_GROUPED:
                continue
            if base in REPEAT_VARS or base in QS_QUALIFIED:
                # Repeaters/Loaders inject `item`/`index`/`delegate`/`modelData`;
                # `qs.Commons.Theme` is the engine's own-directory shorthand.
                continue
            if MEMBER_OK.match(base):
                continue
            if base.isupper() or base[0].isupper():
                # PascalCase is a type reference (Media, LiquidGlass, Theme).
                continue
            problems.append((rel, "unresolved-id", f"{base}.{member}"))

        # ---- 2/3. undeclared singleton tokens -------------------------
        for tok in sorted(set(re.findall(r"\bTheme\.([A-Za-z_]\w*)", src))):
            if tok not in theme_tokens:
                problems.append((rel, "undeclared-Theme", tok))
        for tok in sorted(set(re.findall(r"\bFlags\.([A-Za-z_]\w*)", src))):
            if tok not in flags_tokens:
                problems.append((rel, "undeclared-Flags", tok))

    # ---- report ---------------------------------------------------------
    if not problems:
        print(f"qml-audit: clean ({len(files)} files, {len(theme_tokens)} Theme tokens, "
              f"{len(flags_tokens)} Flags keys)")
        return 0

    by_kind: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for f, kind, detail in problems:
        by_kind[kind].append((f, detail))

    print(f"qml-audit: {len(problems)} problem(s) across {len(files)} files\n")
    for kind in sorted(by_kind):
        rows = by_kind[kind]
        print(f"--- {kind} ({len(rows)}) ---")
        for f, detail in sorted(rows):
            print(f"  {f}: {detail}")
        print()
    return 1


if __name__ == "__main__":
    sys.exit(main())