#!/bin/bash
# lib/ui.sh - shared output helper for the 0k-aws shell scripts.
#
# Owns the mechanics every status layout needs:
#   - status rows on stderr, pipeable data on stdout
#   - color only when the target fd is a TTY and NO_COLOR is unset
#   - -q / --quiet (drops the banner, header, and non-error rows)
#   - a reversible escape for caller-derived data on human-facing status lines
#
# Banner text and column layout stay in the script. Source this file; it is
# never executed directly. A script copied alone (for example into CloudShell)
# will not find the helper unless scripts/lib/ui.sh is copied with the script.

if [ -n "${__UI_SH_LOADED:-}" ]; then
    return 0
fi
__UI_SH_LOADED=1

UI_QUIET="${UI_QUIET:-false}"

ui_quiet() { UI_QUIET=true; }
ui_is_quiet() { [ "$UI_QUIET" = true ]; }

# True when the given fd is a TTY and NO_COLOR is unset. fd 2 is stderr.
ui_color_enabled() {
    local fd="${1:-2}"
    [ -z "${NO_COLOR:-}" ] || return 1
    [ -t "$fd" ]
}

# Print the ANSI code for a color name when color is on for fd (default 2).
# Names: reset red green yellow blue cyan gray bold.
ui_color() {
    local name="$1"
    local fd="${2:-2}"
    ui_color_enabled "$fd" || return 0
    case "$name" in
        reset)  printf '\033[0m' ;;
        red)    printf '\033[31m' ;;
        green)  printf '\033[32m' ;;
        yellow) printf '\033[33m' ;;
        blue)   printf '\033[34m' ;;
        cyan)   printf '\033[36m' ;;
        gray)   printf '\033[90m' ;;
        bold)   printf '\033[1m' ;;
        *)      return 0 ;;
    esac
}

# Status rows: stderr. ui_row obeys --quiet; ui_always does not.
ui_row() {
    ui_is_quiet && return 0
    printf '%s\n' "$*" >&2
}

ui_always() {
    printf '%s\n' "$*" >&2
}

# One-line header for a run (stderr, quiet-gated, highlighted).
ui_header() {
    ui_is_quiet && return 0
    printf '%s%s%s\n' "$(ui_color bold)" "$*" "$(ui_color reset)" >&2
}

# Full banner: read lines on stdin, emit on stderr unless quiet.
ui_banner() {
    if ui_is_quiet; then
        cat >/dev/null
    else
        cat >&2
    fi
}

# Pipeable data: stdout, no color, never suppressed by quiet.
ui_out() {
    printf '%s\n' "$*"
}

# --- reversible escape (any byte, including ASCII SUB 0x1a) ---------------
# Encode existing SUB to SUB 's' first, then backslash to SUB 'b'. The result
# has no raw backslash, so trusted color tokens cannot be forged from data.
# Decode SUB 'b' before SUB 's' so an original SUB + 'b' is not a backslash.
ui_esc_data() {
    local s="$1"
    s="${s//$'\x1a'/$'\x1as'}"
    s="${s//\\/$'\x1ab'}"
    printf '%s' "$s"
}

ui_unesc_data() {
    local s="$1"
    s="${s//$'\x1ab'/\\}"
    s="${s//$'\x1as'/$'\x1a'}"
    printf '%s' "$s"
}

# Remove ANSI SGR sequences so width math uses the visible string.
ui_strip_colors() {
    local s="$1"
    local esc=$'\e['
    local out="" head rest
    while [[ "$s" == *"$esc"* ]]; do
        head="${s%%"$esc"*}"
        out+="$head"
        rest="${s#*"$esc"}"
        case "$rest" in
            *m*) s="${rest#*m}" ;;
            *)   s="$rest"; break ;;
        esac
    done
    printf '%s' "$out$s"
}

# Visible, decoded form of a status row (for width math).
ui_visible_plain() {
    ui_unesc_data "$(ui_strip_colors "$1")"
}
