#!/bin/bash

set -euo pipefail

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Regression probe for aws-sso-check.sh panel/log rendering.

Covers ASCII SUB (0x1a) reversibility and the #46 token-safety
guarantees (literal backslash sequences, no TTY escape injection,
aligned panel frames). No AWS login.

Options:
  --help, -h         Show this help message

EOF
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/auth/scripts/aws-sso-check.sh"
PASS=0
FAIL=0

die() { echo "FAIL: $*" >&2; exit 1; }

ok() {
    echo "PASS: $*"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL=$((FAIL + 1))
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

[ -f "$SCRIPT" ] || die "missing $SCRIPT"
command -v python3 >/dev/null || die "python3 is required for this probe"

write_sso_config() {
    local dest="$1"
    mkdir -p "$(dirname "$dest")"
    cat > "$dest" << 'EOF'
[profile probe]
sso_start_url = https://example.awsapps.com/start
sso_region = us-east-1
sso_account_id = 111122223333
sso_role_name = AdministratorAccess
region = us-east-1
EOF
}

# Run --check-config; print combined stdout+stderr. $1 = AWS_CONFIG_FILE.
run_check_config() {
    local cfg="$1"
    shift
    AWS_CONFIG_FILE="$cfg" bash "$SCRIPT" --check-config "$@" 2>&1
}

# Same, forced TTY via script(1).
run_check_config_tty() {
    local cfg="$1"
    script -qec "AWS_CONFIG_FILE=$(printf '%q' "$cfg") bash $(printf '%q' "$SCRIPT") --check-config" /dev/null
}

assert_panel_aligned() {
    local out="$1"
    local label="$2"
    python3 -c '
import sys
out, label = sys.argv[1], sys.argv[2]
lines = [ln for ln in out.splitlines() if ln.startswith("+") or ln.startswith("|")]
if len(lines) < 3:
    raise SystemExit(f"{label}: expected a 3-line panel, got {len(lines)}")
widths = [len(ln) for ln in lines]
if len(set(widths)) != 1:
    raise SystemExit(f"{label}: panel widths {widths} are not aligned")
if not lines[0].startswith("+") or not lines[-1].startswith("+"):
    raise SystemExit(f"{label}: panel frame missing")
print(widths[0])
' "$out" "$label"
}

# Fail if the panel body contains a real ESC byte.
assert_panel_no_esc() {
    local out="$1"
    local label="$2"
    python3 -c '
import sys
out, label = sys.argv[1], sys.argv[2]
body = "\n".join(ln for ln in out.splitlines() if ln.startswith("|"))
if "\x1b" in body:
    raise SystemExit(f"{label}: panel body contains ESC")
' "$out" "$label"
}

echo "== aws-sso-check render probe =="

# --- 1. AWS_CONFIG_FILE path contains ASCII SUB ---
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SUB=$'\x1a'
CONF_DIR="$TMP/confi${SUB}SUBDATA"
write_sso_config "$CONF_DIR/config"

echo "-- SUB in AWS_CONFIG_FILE (non-TTY) --"
OUT=$(run_check_config "$CONF_DIR/config" | cat)
if WIDTH=$(assert_panel_aligned "$OUT" "sub-nontty"); then
    ok "SUB non-TTY panel aligned (width $WIDTH)"
else
    fail "SUB non-TTY panel aligned"
fi
assert_panel_no_esc "$OUT" "sub-nontty" && ok "SUB non-TTY panel has no ESC" || fail "SUB non-TTY panel has no ESC"
NEEDLE="$CONF_DIR/config" LABEL="sub-nontty" \
    python3 -c '
import os, sys
out = sys.stdin.read() if False else sys.argv[1]
out, label, needle = sys.argv[1], os.environ["LABEL"], os.environ["NEEDLE"]
if needle not in out:
    raise SystemExit(f"{label}: full path missing from output")
logs = [ln for ln in out.splitlines() if "Inspecting SSO profiles in " in ln]
panels = [ln for ln in out.splitlines() if ln.startswith("|")]
if not logs:
    raise SystemExit(f"{label}: missing Inspecting log line")
if needle not in logs[0]:
    raise SystemExit(f"{label}: log lost SUB path (got {logs[0]!r})")
if "INJECTED" in logs[0].split(needle, 1)[-1] and "\n" in logs[0]:
    raise SystemExit(f"{label}: log split across lines")
if not any(needle in ln for ln in panels):
    raise SystemExit(f"{label}: panel lost SUB path")
# old collision: panel showed backslash in place of SUB
for ln in panels:
    if needle in ln:
        continue
    if "confi\\SUBDATA" in ln or "confi\\\\SUBDATA" in ln:
        raise SystemExit(f"{label}: panel rendered SUB as backslash: {ln!r}")
if "\x1a" not in out:
    raise SystemExit(f"{label}: SUB byte absent from entire output")
' "$OUT" && ok "SUB non-TTY log+panel keep 0x1a" || fail "SUB non-TTY log+panel keep 0x1a"

echo "-- SUB in AWS_CONFIG_FILE (TTY) --"
if command -v script >/dev/null; then
    OUT_TTY=$(run_check_config_tty "$CONF_DIR/config" || true)
    # script(1) may wrap with CR; strip CR for checks
    OUT_TTY="${OUT_TTY//$'\r'/}"
    if WIDTH=$(assert_panel_aligned "$OUT_TTY" "sub-tty"); then
        ok "SUB TTY panel aligned (width $WIDTH)"
    else
        fail "SUB TTY panel aligned"
    fi
    NEEDLE="$CONF_DIR/config" LABEL="sub-tty" python3 -c '
import os, sys
out, label, needle = sys.argv[1], os.environ["LABEL"], os.environ["NEEDLE"]
panels = [ln for ln in out.splitlines() if ln.startswith("|")]
logs = [ln for ln in out.splitlines() if "Inspecting SSO profiles in " in ln]
if not any(needle in ln for ln in logs):
    raise SystemExit(f"{label}: TTY log lost SUB path")
if not any(needle in ln for ln in panels):
    raise SystemExit(f"{label}: TTY panel lost SUB path")
body = "\n".join(panels)
# trusted colors may add ESC in TTY; those sit in Succeeded/Failed or log
# prefix, not in the config path itself. Path must appear as literal bytes.
if needle not in body:
    raise SystemExit(f"{label}: TTY panel body missing path")
' "$OUT_TTY" && ok "SUB TTY log+panel keep 0x1a" || fail "SUB TTY log+panel keep 0x1a"
else
    echo "SKIP: script(1) not available for TTY probe"
fi

# --- 2. Profile value and rc-file path containing SUB (check-env) ---
echo "-- SUB in AWS_PROFILE and rc path (check-env) --"
ENVHOME="$TMP/envhome${SUB}rc"
mkdir -p "$ENVHOME"
PROFILE_VAL="probe${SUB}profile"
printf 'export AWS_PROFILE=%s\n' "$PROFILE_VAL" > "$ENVHOME/.bashrc"
# No .bash_profile so the script warns; still prints the bashrc panel.
OUT_ENV=$(HOME="$ENVHOME" bash "$SCRIPT" --check-env 2>&1 || true)
NEEDLE_PROFILE="$PROFILE_VAL" NEEDLE_RC="$ENVHOME/.bashrc" python3 -c '
import os, sys
out = sys.argv[1]
prof, rc = os.environ["NEEDLE_PROFILE"], os.environ["NEEDLE_RC"]
panels = [ln for ln in out.splitlines() if ln.startswith("|")]
logs = [ln for ln in out.splitlines() if not ln.startswith("|") and not ln.startswith("+")]
if not any(prof in ln for ln in logs):
    raise SystemExit("check-env log missing SUB profile")
if not any(prof in ln for ln in panels):
    raise SystemExit("check-env panel missing SUB profile")
if not any(rc in ln for ln in panels):
    raise SystemExit("check-env panel missing SUB rc path")
' "$OUT_ENV" && ok "SUB profile + rc path in log and panel" || fail "SUB profile + rc path in log and panel"
if WIDTH=$(assert_panel_aligned "$OUT_ENV" "sub-env"); then
    ok "SUB check-env panel aligned (width $WIDTH)"
else
    fail "SUB check-env panel aligned"
fi

# --- 3. Token-safety from #46: literal \n in path ---
echo "-- literal backslash-n in AWS_CONFIG_FILE --"
NLDIR="$TMP/confi\\nINJECTED"
write_sso_config "$NLDIR/config"
OUT_NL=$(run_check_config "$NLDIR/config")
python3 -c '
import sys
out = sys.argv[1]
needle = sys.argv[2]
# must stay on one log line
logs = [ln for ln in out.splitlines() if "Inspecting SSO profiles in " in ln]
if not logs:
    raise SystemExit("missing Inspecting log")
if "INJECTED" in logs[0] and needle not in logs[0]:
    raise SystemExit(f"newline injection in log: {logs[0]!r}")
if needle not in logs[0]:
    raise SystemExit(f"log missing literal path {needle!r}: {logs[0]!r}")
panels = [ln for ln in out.splitlines() if ln.startswith("|")]
if not any(needle in ln for ln in panels):
    raise SystemExit("panel missing literal \\\\n path")
# INJECTED must not appear as its own line inside the panel
for ln in out.splitlines():
    if ln.strip() == "INJECTED" or ln.startswith("INJECTED "):
        raise SystemExit(f"newline injection: {ln!r}")
' "$OUT_NL" "$NLDIR/config" && ok "literal \\\\n stays on one log+panel line" || fail "literal \\\\n stays on one log+panel line"
if WIDTH=$(assert_panel_aligned "$OUT_NL" "bs-n"); then
    ok "backslash-n panel aligned (width $WIDTH)"
else
    fail "backslash-n panel aligned"
fi

# --- 4. Token-like \e[31m in path must not become ANSI ---
echo "-- token-like \\\\e[31m in AWS_CONFIG_FILE --"
TOKDIR="$TMP/confi\\e[31mINJECTED"
write_sso_config "$TOKDIR/config"
OUT_TOK=$(run_check_config "$TOKDIR/config")
python3 -c '
import sys
out, needle = sys.argv[1], sys.argv[2]
if "\x1b" in out:
    raise SystemExit("non-TTY output contains ESC")
if needle not in out:
    raise SystemExit("missing token-like path")
panels = [ln for ln in out.splitlines() if ln.startswith("|")]
if not any(needle in ln for ln in panels):
    raise SystemExit("panel missing token-like path")
' "$OUT_TOK" "$TOKDIR/config" && ok "non-TTY token-like path is literal, no ESC" || fail "non-TTY token-like path is literal, no ESC"

if command -v script >/dev/null; then
    OUT_TOK_TTY=$(run_check_config_tty "$TOKDIR/config" || true)
    OUT_TOK_TTY="${OUT_TOK_TTY//$'\r'/}"
    NEEDLE="$TOKDIR/config" python3 -c '
import os, sys
out, needle = sys.argv[1], os.environ["NEEDLE"]
panels = [ln for ln in out.splitlines() if ln.startswith("|")]
body = "\n".join(panels)
if needle not in body:
    raise SystemExit("TTY panel missing token-like path")
# ESC may appear in colored log prefixes, but not inside the path
idx = body.find(needle)
chunk = body[idx:idx+len(needle)]
if "\x1b" in chunk:
    raise SystemExit("TTY injected ESC into config path")
' "$OUT_TOK_TTY" && ok "TTY token-like path has zero ESC in the path" || fail "TTY token-like path has zero ESC in the path"
fi

# --- 5. Mixed SUB + backslash + SUB+"b" (decode-order trap) ---
echo "-- mixed SUB, backslash, and SUB+b sequence --"
MIXDIR="$TMP/a${SUB}b\\c${SUB}s"
write_sso_config "$MIXDIR/config"
OUT_MIX=$(run_check_config "$MIXDIR/config")
NEEDLE="$MIXDIR/config" python3 -c '
import os, sys
out, needle = sys.argv[1], os.environ["NEEDLE"]
logs = [ln for ln in out.splitlines() if "Inspecting SSO profiles in " in ln]
panels = [ln for ln in out.splitlines() if ln.startswith("|")]
if not logs or needle not in logs[0]:
    raise SystemExit("mixed: log mismatch")
if not any(needle in ln for ln in panels):
    raise SystemExit("mixed: panel mismatch")
' "$OUT_MIX" && ok "mixed SUB/backslash path round-trips" || fail "mixed SUB/backslash path round-trips"
if WIDTH=$(assert_panel_aligned "$OUT_MIX" "mixed"); then
    ok "mixed path panel aligned (width $WIDTH)"
else
    fail "mixed path panel aligned"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
