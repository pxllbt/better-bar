#!/usr/bin/env bash
# Keybinding browser for Better Bar's launcher.
#
# `omarchy-menu-keybindings` is the stock entry point and it works right up to
# the last line: it builds the full binding table (cached under
# ~/.cache/omarchy/keybindings-<hash>.records), then hands the list to
# `omarchy-menu-select` to pick from. That selector summons `omarchy.menu`,
# which is in disabledPlugins on this desktop, so the list is built and then
# thrown away with nothing on screen. `SUPER + K` looks like it does nothing.
#
# So this exposes the same table two ways the launcher can use:
#
#   --print          one "MODIFIERS + KEY → action" label per line, for the
#                    menu provider to turn into rows
#   --dispatch LABEL re-find that label in the cache and run it
#
# The records and their priority ordering are the stock ones, read straight out
# of the stock cache rather than reimplemented: this only adds the dispatch half
# that `omarchy-menu-select` used to provide.
#
# `omarchy-menu-keybindings` remains installed and unchanged; only the selection
# step is replaced.

set -uo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy"
STOCK=/usr/bin/omarchy-menu-keybindings

# Newest cache file, which is the one the stock script last wrote. Falls back to
# building the table when there is no cache yet.
cache_file() {
  local newest
  newest=$(ls -t "$CACHE_DIR"/keybindings-*.records 2>/dev/null | head -1)
  if [[ -n "$newest" && -s "$newest" ]]; then
    printf '%s' "$newest"
    return 0
  fi
  return 1
}

# The full records: "display<TAB>dispatcher<TAB>arg", tab-separated.
records() {
  local file
  if file=$(cache_file); then
    cat "$file"
  else
    # No cache: let the stock script build one. Its stdout here is display-only,
    # which still serves --print; --dispatch then reports that it cannot run a
    # single binding rather than guessing.
    "$STOCK" --print
  fi
}

case "${1:---print}" in
  --print)
    records | cut -f1
    ;;

  --dispatch)
    selection="${2:-}"
    if [[ -z "$selection" ]]; then
      echo "keybindings.sh: --dispatch needs a label" >&2
      exit 1
    fi

    file=$(cache_file) || {
      echo "keybindings.sh: no keybinding cache; run --print first" >&2
      exit 1
    }

    # Exact match on the display text, which is what the row carried. First hit
    # wins, matching the stock script's own selection lookup.
    record=$(awk -F '\t' -v s="$selection" '$1 == s { print; exit }' "$file")
    if [[ -z "$record" ]]; then
      echo "keybindings.sh: no binding named '$selection'" >&2
      exit 1
    fi

    dispatcher=$(cut -f2 <<<"$record")
    arg=$(cut -f3- <<<"$record")

    trim() {
      local value="$1"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      printf '%s' "$value"
    }

    # Same three cases the stock script dispatches, minus the selector.
    case "$dispatcher" in
      exec)
        command=$(trim "$arg")
        [[ -z "$command" ]] && exit 1
        hyprctl dispatch "hl.dsp.exec_cmd($(jq -Rn --arg v "$command" '$v|@json'))" >/dev/null 2>&1 \
          || hyprctl dispatch exec "$command"
        ;;
      sendshortcut)
        IFS=',' read -r mods key window _ <<<"$arg"
        mods=$(trim "${mods:-}")
        key=$(trim "${key:-}")
        window=$(trim "${window:-}")
        [[ -z "$window" ]] && window="activewindow"
        if [[ -n "$key" ]]; then
          m=$(jq -Rn --arg v "$mods" '$v|@json')
          k=$(jq -Rn --arg v "$key" '$v|@json')
          hyprctl dispatch "hl.dsp.send_key_state({ mods = $m, key = $k, state = \"down\", window = \"$window\" })" >/dev/null 2>&1 && {
            sleep 0.05
            hyprctl dispatch "hl.dsp.send_key_state({ mods = $m, key = $k, state = \"up\", window = \"$window\" })"
            exit 0
          }
        fi
        hyprctl dispatch sendshortcut "$arg"
        ;;
      lua)
        [[ -n "$arg" ]] && hyprctl dispatch "$arg"
        ;;
      "")
        echo "keybindings.sh: '$selection' has no dispatcher" >&2
        exit 1
        ;;
      *)
        if [[ -n "$arg" ]]; then
          hyprctl dispatch "$dispatcher" "$arg"
        else
          hyprctl dispatch "$dispatcher"
        fi
        ;;
    esac
    ;;

  *)
    echo "usage: keybindings.sh [--print | --dispatch LABEL]" >&2
    exit 1
    ;;
esac