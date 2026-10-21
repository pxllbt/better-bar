#!/usr/bin/env bash
# Asserts that better-doctor.sh inspects processes, layers, daemons, and symlinks,
# and supports --fix and --json flags.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DOCTOR="$ROOT/scripts/better-doctor.sh"

failed=0
ok() {
    if [ "$2" = "$3" ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected: %s\n  got:      %s\n' "$1" "$3" "$2"
    fi
}
has() {
    if [ "$2" -gt 0 ]; then
        printf 'PASS %s\n' "$1"
    else
        failed=$((failed + 1))
        printf 'FAIL %s\n  expected to find: %s\n' "$1" "$3"
    fi
}

[ -f "$DOCTOR" ] || { echo "no better-doctor.sh at $DOCTOR" >&2; exit 1; }

# 1. better-doctor.sh must be executable
ok "better-doctor.sh is executable" \
    "$([ -x "$DOCTOR" ] && echo "yes" || echo "no")" "yes"

# 2. Inspects bar processes and supervisor
has "better-doctor checks bar processes" \
    "$(grep -cE 'better-watch|quickshell' "$DOCTOR")" "process check"

# 3. Inspects layer-shell namespaces
has "better-doctor checks hyprctl layers" \
    "$(grep -c 'hyprctl layers' "$DOCTOR")" "hyprctl layers"

# 4. Inspects awww-daemon and symlinks
has "better-doctor checks awww-daemon" \
    "$(grep -c 'awww' "$DOCTOR")" "awww"

has "better-doctor checks background symlink" \
    "$(grep -c 'current/background' "$DOCTOR")" "current/background"

# 5. Supports --fix and --json
has "better-doctor supports --fix flag" \
    "$(grep -c -- '--fix' "$DOCTOR")" "--fix"

has "better-doctor supports --json flag" \
    "$(grep -c -- '--json' "$DOCTOR")" "--json"

# 3. Only counts pids still alive, so a bar that exits between the ps and the
# count is not reported as a duplicate
has "better-doctor revalidates pids against /proc before counting" \
    "$(grep -c '\[ -d "/proc/\$pid" \] || continue' "$DOCTOR")" "pid liveness filter"

# 4. Screens: the two layout faults that break silently -- a duplicated output and
# an unparseable file -- plus a screen count. No editor, no drift; each is the
# whole check in a form a `grep` can confirm.
has "better-doctor reports the screen count from hyprctl monitors" \
    "$(grep -c 'hyprctl monitors -j' "$DOCTOR")" "hyprctl monitors -j"

has "better-doctor flags two hl.monitor blocks naming the same output" \
    "$(grep -c 'uniq -d' "$DOCTOR")" "duplicate-output detection"

has "better-doctor flags a monitors.lua with no hl.monitor block" \
    "$(grep -c "no hl.monitor block at all" "$DOCTOR")" "unparseable-layout detection"

# The stock monitors.lua carries commented-out examples that all name DP-2. A
# check that counted those would fire on every unedited install, so the
# comment-stripping is part of the check, not a nicety.
has "better-doctor ignores commented-out monitor blocks when counting outputs" \
    "$(grep -c "grep -vE '\^\[\[:space:\]\]\*--'" "$DOCTOR")" "comment strip"

# A settings flag can be written AND referenced and still do nothing, if the
# component that reads it ignores it on one path -- which is how Transparency
# mode became a switch that changed nothing at all. A reference sweep cannot see
# that, so the doctor at least catches a flag with no consumer whatsoever.
has "better-doctor flags a settings row that writes a flag nothing reads" \
    "$(grep -c 'settings_dead_flags' "$DOCTOR")" "dead-flag check"

has "the dead-flag check counts script consumers, not only QML" \
    "$(grep -c "include='\*.sh'" "$DOCTOR")" "script consumers counted"
has "the dead-flag check allows flags self-contained in their surface" \
    "$(grep -c 'self_consumed' "$DOCTOR")" "self-contained check"

# ---------------------------------------------------------------------------
# The checks the old doctor did not have.
#
# The old engine reported "All systems healthy" on a tree whose own suite was
# failing eight ways, whose singleton was never registered, and whose settings
# search offered a surface that had been deleted. None of those are liveness
# questions, so none of them were asked. Each one is pinned here so a later
# rewrite cannot quietly drop them again.
# ---------------------------------------------------------------------------

# The report order has to be fixed. A report you cannot diff against last
# week's report is not a report, and the old engine iterated a hash table.
has "the report order is a list, not a hash table" \
    "$(grep -c 'ORDER=()' "$DOCTOR")" "ordered report"

# JSON with a bare printf is not JSON: any value holding a quote or a
# backslash -- a path, an error message -- produces a file no parser accepts.
has "the JSON emitter escapes the values it writes" \
    "$(grep -c 'json_escape' "$DOCTOR")" "json escaping"

# A diagnostic that goes quiet when its tools are missing reports success.
has "the doctor checks its own dependencies before using them" \
    "$(grep -c 'MISSING_DEPS' "$DOCTOR")" "dependency check"

# The tree's own agreement with itself.
has "the doctor checks qmldir registration drift" \
    "$(grep -c 'qmldir_drift' "$DOCTOR")" "qmldir drift check"
has "the doctor checks the surface registry" \
    "$(grep -c 'surface_registry' "$DOCTOR")" "surface registry check"
has "the doctor checks the settings search targets" \
    "$(grep -c 'settings_search_targets' "$DOCTOR")" "settings search check"
has "the doctor checks for flags with no Singleton alias" \
    "$(grep -c 'flags_unaliased' "$DOCTOR")" "unaliased flag check"
has "the doctor checks script syntax" \
    "$(grep -c 'shell_syntax' "$DOCTOR")" "shell syntax check"
has "the doctor runs the project's own test suite" \
    "$(grep -c 'test_suite' "$DOCTOR")" "test suite check"
has "the doctor runs the QML integrity gate" \
    "$(grep -c 'qml_integrity' "$DOCTOR")" "qml integrity check"

# The install directory had three different answers in the tree.
has "the doctor checks the install layout" \
    "$(grep -c 'install_dir' "$DOCTOR")" "install layout check"
has "the doctor checks the launcher's install path" \
    "$(grep -c 'launcher_path' "$DOCTOR")" "launcher path check"

# A checkout on a build agent has no bar and no compositor, so the runtime
# checks would report a broken machine that is actually fine.
has "the doctor has a static mode for source-tree checks only" \
    "$(grep -c 'STATIC_ONLY' "$DOCTOR")" "static mode"

if [ "$failed" -gt 0 ]; then
    printf '\n%s failing\n' "$failed"
    exit 1
fi
printf '\nall green\n'
