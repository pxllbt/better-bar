#!/bin/sh
# Persist one clipboard change for the Better Bar clipboard surface.
#
# `wl-paste --watch` does NOT read the clipboard for you and `cliphist store`
# does NOT read it either -- store takes the content on STDIN. The pair only
# works as a pipe, which is why this lives in its own script: `wl-paste --watch`
# takes exactly one mandatory argument and rejects anything after it, so an
# inline `sh -c` with nested quoting cannot be expressed on its command line.
#
# Upstream shipped `["wl-paste", "--watch", "echo", "x"]`, which pipes the
# copied text into `echo`. That prints "x" and discards the content, so
# `cliphist store` was never invoked anywhere on the box: the db was created
# but stayed empty and `cliphist list` always returned nothing. Same shape as
# Cliphist.qml's own file header -- a wl-paste watcher firing on every change,
# feeding a snapshot that is re-read into `entries` -- except nothing ever fed
# it. Every other stage (thumbnail regeneration, list re-read, dirty/pending
# tracking, respawn) was intact and simply had nothing to show.
#
# The `printf x` is not decorative: Cliphist.qml watches this script's stdout
# for a token to mark the snapshot dirty (or restart the debounce when the
# clipboard surface is open). Dropping it would leave the surface stale until
# it was reopened.
#
# cliphist's stdout is discarded rather than left to merge into that token: an
# error would otherwise prepend itself to the next `onRead` and shift the
# SplitParser's framing.

cliphist store >/dev/null 2>&1

printf x