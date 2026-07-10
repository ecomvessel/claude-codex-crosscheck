#!/usr/bin/env bash
# quick-install.sh — one-command installer for people who have not cloned this repo.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ecomvessel/claude-codex-crosscheck/main/quick-install.sh | bash
#
# Optional for forks/testing:
#   CCX_REPO=your-org/claude-codex-crosscheck CCX_REF=your-branch bash quick-install.sh
set -euo pipefail

CCX_REPO="${CCX_REPO:-ecomvessel/claude-codex-crosscheck}"
CCX_REF="${CCX_REF:-main}"

for bin in curl tar; do
  command -v "$bin" >/dev/null 2>&1 || { echo "$bin is required for quick install." >&2; exit 1; }
done

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Claude ⇄ Codex Cross-Check — quick install"
echo "Downloading ${CCX_REPO}@${CCX_REF}..."
curl -fsSL "https://github.com/${CCX_REPO}/archive/${CCX_REF}.tar.gz" -o "$tmpdir/src.tar.gz"
tar -xzf "$tmpdir/src.tar.gz" -C "$tmpdir"

repo_dir="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | sed -n '1p')"
if [ -z "$repo_dir" ] || [ ! -f "$repo_dir/install.sh" ]; then
  echo "Downloaded archive did not contain install.sh." >&2
  exit 1
fi

bash "$repo_dir/install.sh" "$@"
