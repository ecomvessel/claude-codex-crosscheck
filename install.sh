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
#
# Usage:
#   ./install.sh              # install / update
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

case "${1:-}" in
  ""|--uninstall) ;;
  *) echo "Unknown option: ${1}" >&2; echo "Usage: ./install.sh [--uninstall]" >&2; exit 1 ;;
esac

echo "Claude ⇄ Codex Cross-Check"
echo

if [ "${1:-}" = "--uninstall" ]; then
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
echo "To remove later:  ./install.sh --uninstall   (backups are named *.bak-crosscheck.*)"
