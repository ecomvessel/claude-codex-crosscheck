#!/usr/bin/env bash
# install.sh — install the Claude ⇄ Codex cross-check rules.
#
# What it does:
#   • Appends a clearly-marked block to  ~/.claude/CLAUDE.md   (Claude → review with Codex)
#   • Appends a clearly-marked block to  ~/.codex/AGENTS.md    (Codex  → review with Claude)
#   • Creates either file if it does not exist; otherwise leaves everything else untouched.
#   • Re-running REPLACES only its own block (a well-formed BEGIN…END pair). Safe to run again.
#   • Backs up any file it CHANGES to a unique <file>.bak-crosscheck.<random>.
#
# Safety design (hardened after adversarial review):
#   • Markers are matched ONLY as whole lines starting with the sentinel — a file that merely
#     *mentions* the marker text in prose is never touched.
#   • Only a COMPLETE, well-formed BEGIN…END pair is ever removed. A stray/unterminated or nested
#     marker makes the script ABORT that file with a clear message instead of deleting content.
#   • Symlinked targets are written through (the link is preserved); file mode is preserved.
#   • If the resulting content is identical to what's already there, nothing is written at all.
#   • On a FIRST install, a file that already has its OWN cross-check rule (a "Cross-Check" heading)
#     is left untouched so you never end up with two conflicting rules. Once the managed block is
#     in a file, re-runs always update it.
#
# Usage:
#   ./install.sh              # install / update
#   ./install.sh --force      # install even if a hand-written cross-check rule is already there
#   ./install.sh --check      # read-only health check: blocks current? CLIs present? flags still valid?
#   ./install.sh --uninstall  # remove only the managed block from both files
#
# This stacks cleanly on top of other instruction packs (e.g. claude-code-model-switch):
# it never overwrites your existing rules, it only adds/updates its own marked section.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLAUDE_FILE="${HOME}/.claude/CLAUDE.md"
CODEX_FILE="${HOME}/.codex/AGENTS.md"
CLAUDE_TMPL="${SCRIPT_DIR}/templates/claude-crosscheck.md"
CODEX_TMPL="${SCRIPT_DIR}/templates/codex-crosscheck.md"

# strip_block <file> : print <file> with any well-formed managed block(s) removed.
# Exit 0 = clean (block removed, or none present). Exit 2 = unterminated BEGIN (no END).
# Exit 3 = nested BEGIN. On 2/3 the printed output equals the input (nothing dropped) so the
# caller can safely abort without having altered anything.
strip_block() {
  awk '
    BEGIN { inside = 0; nested = 0 }
    /^<!-- BEGIN claude-codex-crosscheck/ {
      if (inside) { nested = 1; buf = buf $0 ORS; next }
      inside = 1; buf = $0 ORS; next
    }
    inside && /^<!-- END claude-codex-crosscheck -->/ {
      inside = 0; buf = ""; next        # complete pair -> drop the whole block
    }
    { if (inside) buf = buf $0 ORS; else print }
    END {
      if (inside) { printf "%s", buf; exit 2 }   # unterminated: emit untouched, signal abort
      if (nested) { exit 3 }
    }
  ' "$1"
}

# trim_trailing_blanks : stdin -> stdout with trailing blank lines removed
trim_trailing_blanks() {
  awk 'NF { last = NR } { line[NR] = $0 } END { for (i = 1; i <= last; i++) print line[i] }'
}

# backup <file> : make a guaranteed-unique backup, print its path.
# Runs inside $(), where errexit is off — every step must check its own failure,
# or a failed cp would hand back an empty backup and let the caller truncate the real file.
backup() {
  local b
  b="$(mktemp "${1}.bak-crosscheck.XXXXXX")" || return 1
  cp "$1" "$b" || { rm -f "$b"; return 1; }
  printf '%s' "$b"
}

# write_through <src> <target> : replace target's CONTENT from src, preserving a symlink target
# and the existing file mode (redirection truncates in place rather than swapping the inode).
write_through() { cat "$1" > "$2"; }

# run strip_block capturing output + exit code without tripping `set -e`
strip_to() {  # <target> <out_file> ; returns strip_block's exit code
  local rc=0
  set +e
  strip_block "$1" > "$2"
  rc=$?
  set -e
  return "$rc"
}

FAILED=0
abort_marker() {  # <rc> <target> <label>
  FAILED=1
  case "$1" in
    2) echo "✗ ${3}: ${2} has a BEGIN marker with no matching END — left UNTOUCHED. Fix it by hand, then re-run." ;;
    3) echo "✗ ${3}: ${2} has nested/overlapping markers — left UNTOUCHED. Fix it by hand, then re-run." ;;
    *) echo "✗ ${3}: could not read ${2} — left UNTOUCHED." ;;
  esac
}

# guard_regular <target> <label> : succeed only if target is absent or a readable regular file.
# Catches directories and broken symlinks up front, with a real message instead of a mid-run crash.
guard_regular() {
  local target="$1" label="$2"
  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ ! -f "$target" ] || [ ! -r "$target" ]; then
      FAILED=1
      echo "✗ ${label}: ${target} is not a readable regular file (directory or broken symlink?) — left UNTOUCHED."
      return 1
    fi
  fi
  return 0
}

# own_rule_heading <file> : print the first "Cross-Check" heading in <file> (run it on the STRIPPED
# copy, so the managed block's own heading never counts). Exit 1 if there is none.
own_rule_heading() {
  grep -m1 -iE '^#+[[:space:]].*cross-check' "$1"
}

# upsert <target_file> <template_file> <label>
upsert() {
  local target="$1" tmpl="$2" label="$3"
  mkdir -p "$(dirname "$target")"
  guard_regular "$target" "$label" || return 0

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    cp "$tmpl" "$target"
    echo "✓ ${label}: created ${target} with the cross-check block."
    return
  fi

  local stripped rc=0
  stripped="$(mktemp)"
  strip_to "$target" "$stripped" || rc=$?
  if [ "$rc" -ne 0 ]; then abort_marker "$rc" "$target" "$label"; rm -f "$stripped"; return; fi

  # was a block present? (stripped == target means nothing was removed -> this is an append)
  local appending=0
  cmp -s "$stripped" "$target" && appending=1

  # Only a FIRST install is held back by a hand-written rule. Once our block is in the file, updates
  # always go through — otherwise a user could be stranded on an old, broken block.
  local own
  if [ "$appending" -eq 1 ] && [ "$FORCE" -eq 0 ] && own="$(own_rule_heading "$stripped")"; then
    FAILED=1
    echo "✗ ${label}: ${target} already has its own cross-check rule (\"${own}\") — left UNTOUCHED,"
    echo "    so you don't end up with two rules that disagree. Delete or rename that section and"
    echo "    re-run, or re-run with --force to add this one alongside it."
    rm -f "$stripped"; return
  fi

  local newf; newf="$(mktemp)"
  if [ -s "$stripped" ]; then trim_trailing_blanks < "$stripped"; printf '\n'; fi > "$newf"
  cat "$tmpl" >> "$newf"

  if cmp -s "$newf" "$target"; then
    echo "• ${label}: already up to date in ${target} — no change."
    rm -f "$stripped" "$newf"; return
  fi

  local bak
  if ! bak="$(backup "$target")"; then
    FAILED=1
    echo "✗ ${label}: could not create a backup of ${target} — left UNTOUCHED."
    rm -f "$stripped" "$newf"; return
  fi
  write_through "$newf" "$target"
  if [ "$appending" -eq 1 ]; then
    echo "✓ ${label}: appended the cross-check block to ${target}  (backup: ${bak##*/})."
  else
    echo "✓ ${label}: updated the cross-check block in ${target}  (backup: ${bak##*/})."
  fi
  rm -f "$stripped" "$newf"
}

# remove <target_file> <label>
remove() {
  local target="$1" label="$2"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then echo "• ${label}: nothing to remove (${target} does not exist)."; return; fi
  guard_regular "$target" "$label" || return 0

  local stripped rc=0
  stripped="$(mktemp)"
  strip_to "$target" "$stripped" || rc=$?
  if [ "$rc" -ne 0 ]; then abort_marker "$rc" "$target" "$label"; rm -f "$stripped"; return; fi

  if cmp -s "$stripped" "$target"; then
    echo "• ${label}: nothing to remove in ${target}."
    rm -f "$stripped"; return
  fi

  local finalf; finalf="$(mktemp)"
  trim_trailing_blanks < "$stripped" > "$finalf"

  local bak
  if ! bak="$(backup "$target")"; then
    FAILED=1
    echo "✗ ${label}: could not create a backup of ${target} — left UNTOUCHED."
    rm -f "$stripped" "$finalf"; return
  fi
  write_through "$finalf" "$target"
  echo "✓ ${label}: removed the cross-check block from ${target}  (backup: ${bak##*/})."
  rm -f "$stripped" "$finalf"
}

# ---------- --check : read-only health check (no API calls, writes nothing) ----------
PROBLEMS=0
problem() { PROBLEMS=$((PROBLEMS+1)); echo "✗ $1"; }

# extract_block <file> : print the first managed block (BEGIN..END lines included)
extract_block() {
  awk '/^<!-- BEGIN claude-codex-crosscheck/ { p = 1 }
       p { print }
       p && /^<!-- END claude-codex-crosscheck -->/ { exit }' "$1"
}

check_file() {  # <target> <template> <label>
  local target="$1" tmpl="$2" label="$3"
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    problem "${label}: ${target} does not exist — not installed. Run ./install.sh"; return
  fi
  if [ ! -f "$target" ] || [ ! -r "$target" ]; then
    problem "${label}: ${target} is not a readable regular file."; return
  fi
  local stripped rc=0 blk
  stripped="$(mktemp)"
  strip_to "$target" "$stripped" || rc=$?
  if [ "$rc" -ne 0 ]; then
    problem "${label}: ${target} has broken BEGIN/END markers — fix by hand, then re-run ./install.sh"
    rm -f "$stripped"; return
  fi
  blk="$(mktemp)"
  extract_block "$target" > "$blk"
  local own="" has_own=0
  own="$(own_rule_heading "$stripped")" && has_own=1
  if [ ! -s "$blk" ] && [ "$has_own" -eq 1 ]; then
    echo "• ${label}: ${target} uses its own hand-written cross-check rule (\"${own}\"), not this"
    echo "    installer's block. Fine if that's on purpose; this tool won't check or change it."
  elif [ ! -s "$blk" ]; then
    problem "${label}: no cross-check block in ${target} — not installed. Run ./install.sh"
  elif cmp -s "$blk" "$tmpl"; then
    echo "✓ ${label}: cross-check block in ${target} is current."
  else
    problem "${label}: the block in ${target} is outdated or was hand-edited. Re-run ./install.sh to refresh it."
  fi
  if [ -s "$blk" ] && [ "$has_own" -eq 1 ]; then
    echo "⚠ ${label}: ${target} ALSO has a hand-written cross-check rule (\"${own}\") — two rules may disagree."
  fi
  rm -f "$stripped" "$blk"
}

check_cli() {  # <name> <help-command...> -- <required flag...>
  local name="$1"; shift
  local cmd=() flags=() seen=0 a h f missing=""
  for a in "$@"; do
    if [ "$seen" -eq 0 ] && [ "$a" = "--" ]; then seen=1; continue; fi
    if [ "$seen" -eq 0 ]; then cmd+=("$a"); else flags+=("$a"); fi
  done
  if ! command -v "$name" >/dev/null 2>&1; then
    problem "'${name}' is not on PATH — reviews that should go to ${name} will only be self-reviews (single-vendor)."
    return
  fi
  h="$("${cmd[@]}" 2>&1 || true)"
  for f in "${flags[@]}"; do
    [[ "$h" == *"$f"* ]] || missing="${missing} ${f}"
  done
  if [ -n "$missing" ]; then
    problem "'${name}' no longer lists:${missing} — this CLI version renamed flags the rules depend on. See Troubleshooting in the README."
  else
    echo "✓ '${name}' found ($(command -v "$name")) and supports every flag the rules use."
  fi
}

usage() {
  echo "Usage: ./install.sh [--force | --check | --uninstall]"
  echo "  (no option)  install or update the cross-check blocks"
  echo "  --force      install even if a hand-written cross-check rule is already there"
  echo "  --check      read-only health check; changes nothing"
  echo "  --uninstall  remove only this installer's blocks"
}

MODE=install
FORCE=0
set_mode() {
  if [ "$MODE" != install ]; then echo "Pick one of --check / --uninstall, not both." >&2; usage >&2; exit 1; fi
  MODE="$1"
}
for arg in "$@"; do
  case "$arg" in
    --uninstall) set_mode uninstall ;;
    --check)     set_mode check ;;
    --force)     FORCE=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: ${arg}" >&2; usage >&2; exit 1 ;;
  esac
done

echo "Claude ⇄ Codex Cross-Check"
echo

if [ "$MODE" = "check" ]; then
  check_file "$CLAUDE_FILE" "$CLAUDE_TMPL" "Claude"
  check_file "$CODEX_FILE"  "$CODEX_TMPL"  "Codex"
  check_cli claude claude --help -- --print --tools --permission-mode --strict-mcp-config
  check_cli codex  codex exec --help -- --sandbox --skip-git-repo-check
  echo
  if [ "$PROBLEMS" -eq 0 ]; then
    echo "All good. Last step only you can do: start a NEW session and ask for a plan that touches auth"
    echo "or payments — you should see the other CLI actually run and a '🔁 Cross-check:' receipt."
    exit 0
  fi
  echo "${PROBLEMS} problem(s) found (see ✗ above)."
  exit 1
fi

if [ "$MODE" = "uninstall" ]; then
  remove "$CLAUDE_FILE" "Claude"
  remove "$CODEX_FILE"  "Codex"
  echo
  if [ "$FAILED" -eq 1 ]; then
    echo "Partially uninstalled — one file was left untouched (see ✗ above). Fix it and re-run."
  else
    echo "Uninstalled. Your other rules were left untouched."
  fi
  echo "(Backups named *.bak-crosscheck.* remain in ~/.claude and ~/.codex — delete them whenever.)"
  exit "$FAILED"
fi

upsert "$CLAUDE_FILE" "$CLAUDE_TMPL" "Claude"
upsert "$CODEX_FILE"  "$CODEX_TMPL"  "Codex"

if [ "$FAILED" -eq 1 ]; then
  echo
  echo "One file was left untouched (see ✗ above). Fix it and re-run."
  exit 1
fi

echo
# Presence checks — warn but don't fail; a CLI may be installed later.
have_claude=0; have_codex=0
command -v claude >/dev/null 2>&1 && have_claude=1
command -v codex  >/dev/null 2>&1 && have_codex=1
[ "$have_claude" -eq 1 ] || echo "⚠  'claude' not found on PATH — install Claude Code for the Codex→Claude direction to work."
[ "$have_codex"  -eq 1 ] || echo "⚠  'codex' not found on PATH — install Codex CLI for the Claude→Codex direction to work."
if [ "$have_claude" -eq 1 ] && [ "$have_codex" -eq 1 ]; then
  echo "Both CLIs detected. The cross-check is live in both directions."
fi
echo
echo "Done. Start a new session in either tool and it will cross-check danger/design plans automatically."
echo "Health check any time:  ./install.sh --check"
echo "To remove later:        ./install.sh --uninstall   (backups are named *.bak-crosscheck.*)"
