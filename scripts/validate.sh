#!/usr/bin/env bash
# validate.sh — repo self-test. Run from anywhere: bash scripts/validate.sh
# Checks repo structure, template integrity, and install.sh's actual safety behaviors
# in a throwaway HOME. Exits non-zero on any failure.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { # <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# ---------- structure ----------
check "install.sh exists and is executable"      test -x "$REPO/install.sh"
check "quick-install.sh exists"                  test -f "$REPO/quick-install.sh"
check "README.md exists"                         test -s "$REPO/README.md"
check "LICENSE exists"                           test -s "$REPO/LICENSE"
check "claude template exists"                   test -s "$REPO/templates/claude-crosscheck.md"
check "codex template exists"                    test -s "$REPO/templates/codex-crosscheck.md"

# ---------- template integrity ----------
for t in claude-crosscheck.md codex-crosscheck.md; do
  f="$REPO/templates/$t"
  b=$(grep -c '^<!-- BEGIN claude-codex-crosscheck' "$f")
  e=$(grep -c '^<!-- END claude-codex-crosscheck -->' "$f")
  if [ "$b" = 1 ] && [ "$e" = 1 ]; then ok "[$t] exactly one BEGIN/END marker pair"; else bad "[$t] marker pairs (BEGIN=$b END=$e)"; fi
  if grep -qiE 'TODO|FIXME|PLACEHOLDER|<your-' "$f"; then bad "[$t] contains placeholder text"; else ok "[$t] no placeholder text"; fi
done
# the codex template must teach the sandbox/Keychain handling and must not reference tooling that
# does not ship with this repo
check "[codex tmpl] documents the Keychain false 'Not logged in'"  grep -q 'Keychain' "$REPO/templates/codex-crosscheck.md"
check "[codex tmpl] no reference to a claude-review wrapper"       bash -c "! grep -q 'claude-review' '$REPO/templates/codex-crosscheck.md'"
check "[both tmpl] receipt rule present"  bash -c "grep -ql 'Cross-check:' '$REPO/templates/claude-crosscheck.md' && grep -ql 'Cross-check:' '$REPO/templates/codex-crosscheck.md'"

# ---------- install.sh behavior in a sandbox HOME ----------
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
run_install() { HOME="$SB/home" bash "$REPO/install.sh" "$@" 2>&1; }

# fresh install creates both files identical to the templates
rm -rf "$SB/home"; mkdir -p "$SB/home"
out="$(run_install)"; rc=$?
[ $rc -eq 0 ] && ok "[fresh] install exits 0" || bad "[fresh] install exits 0 (rc=$rc)"
check "[fresh] Claude file created equal to template"  cmp -s "$SB/home/.claude/CLAUDE.md" "$REPO/templates/claude-crosscheck.md"
check "[fresh] Codex file created equal to template"   cmp -s "$SB/home/.codex/AGENTS.md"  "$REPO/templates/codex-crosscheck.md"

# re-run is a no-op (idempotent) and leaves no backups behind
out="$(run_install)"
echo "$out" | grep -q "already up to date" && ok "[rerun] reports already up to date" || bad "[rerun] reports already up to date"
n=$(find "$SB/home" -name '*.bak-crosscheck.*' | wc -l | tr -d ' ')
[ "$n" = 0 ] && ok "[rerun] no backup files created on a no-op" || bad "[rerun] no backup files created on a no-op ($n found)"

# appending to an existing file preserves the user's own rules and makes a backup
rm -rf "$SB/home"; mkdir -p "$SB/home/.claude" "$SB/home/.codex"
printf '# My own rules\nnever delete prod\n' > "$SB/home/.claude/CLAUDE.md"
run_install >/dev/null
check "[append] user's own rules preserved"  grep -q 'never delete prod' "$SB/home/.claude/CLAUDE.md"
check "[append] block appended"              grep -q '^<!-- BEGIN claude-codex-crosscheck' "$SB/home/.claude/CLAUDE.md"
n=$(find "$SB/home/.claude" -name '*.bak-crosscheck.*' | wc -l | tr -d ' ')
[ "$n" = 1 ] && ok "[append] exactly one backup written" || bad "[append] exactly one backup written ($n found)"

# updating replaces ONLY the managed block, still preserving the user's rules
sed -i.orig 's/adversarial/ADVERSARIAL-STALE/' "$SB/home/.claude/CLAUDE.md" 2>/dev/null || true
run_install >/dev/null
check "[update] stale block content replaced"  bash -c "! grep -q 'ADVERSARIAL-STALE' '$SB/home/.claude/CLAUDE.md'"
check "[update] user's own rules preserved"    grep -q 'never delete prod' "$SB/home/.claude/CLAUDE.md"

# a broken (unterminated) marker aborts that file untouched and exits non-zero
rm -rf "$SB/home"; mkdir -p "$SB/home/.claude"
printf '<!-- BEGIN claude-codex-crosscheck v1 -->\nno end marker here\n' > "$SB/home/.claude/CLAUDE.md"
cp "$SB/home/.claude/CLAUDE.md" "$SB/broken.orig"
out="$(run_install)"; rc=$?
[ $rc -ne 0 ] && ok "[broken-marker] install exits non-zero" || bad "[broken-marker] install exits non-zero"
check "[broken-marker] file left byte-identical"  cmp -s "$SB/home/.claude/CLAUDE.md" "$SB/broken.orig"

# a prose MENTION of the marker (not at line start) must not be treated as a marker
rm -rf "$SB/home"; mkdir -p "$SB/home/.claude"
printf '# notes\n  the <!-- BEGIN claude-codex-crosscheck marker is discussed here\n' > "$SB/home/.claude/CLAUDE.md"
run_install >/dev/null
check "[prose-mention] prose line preserved"  grep -q 'is discussed here' "$SB/home/.claude/CLAUDE.md"

# uninstall removes only the managed block and keeps the user's rules
rm -rf "$SB/home"; mkdir -p "$SB/home/.claude"
printf '# My own rules\nnever delete prod\n' > "$SB/home/.claude/CLAUDE.md"
run_install >/dev/null
run_install --uninstall >/dev/null
check "[uninstall] managed block removed"     bash -c "! grep -q '^<!-- BEGIN claude-codex-crosscheck' '$SB/home/.claude/CLAUDE.md'"
check "[uninstall] user's own rules survive"  grep -q 'never delete prod' "$SB/home/.claude/CLAUDE.md"

# a symlinked target is written THROUGH (link preserved, referent updated)
rm -rf "$SB/home"; mkdir -p "$SB/home/.claude" "$SB/real"
printf '# real file\n' > "$SB/real/CLAUDE.md"
ln -s "$SB/real/CLAUDE.md" "$SB/home/.claude/CLAUDE.md"
run_install >/dev/null
check "[symlink] link preserved"          test -L "$SB/home/.claude/CLAUDE.md"
check "[symlink] referent got the block"  grep -q '^<!-- BEGIN claude-codex-crosscheck' "$SB/real/CLAUDE.md"

# a directory in the target's place is refused with a clear failure
rm -rf "$SB/home"; mkdir -p "$SB/home/.claude/CLAUDE.md"   # directory, not a file
out="$(run_install)"; rc=$?
[ $rc -ne 0 ] && ok "[dir-target] install exits non-zero" || bad "[dir-target] install exits non-zero"
echo "$out" | grep -q "not a readable regular file" && ok "[dir-target] clear error message" || bad "[dir-target] clear error message"

echo
echo "passed: $PASS   failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo "FAIL"; exit 1; fi
echo "PASS"
