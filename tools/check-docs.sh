#!/usr/bin/env bash
# Fail if any fenced code block is missing a language (markdownlint MD040).
#
# Kept as a self-contained shell check rather than pulling in markdownlint so CI
# needs no node toolchain for a rule this repo only has one of.
set -euo pipefail
cd "$(dirname "$0")/.."
bad=0
while IFS= read -r f; do
  awk -v F="$f" '
    /^```/ { n++; if (n % 2 == 1 && $0 == "```") { print F ":" NR ": fenced block has no language (MD040)"; rc=1 } }
    END { exit rc }
  ' "$f" || bad=1
done < <(git ls-files '*.md')
[ "$bad" = 0 ] && echo "docs: all fenced code blocks are labelled" || exit 1
