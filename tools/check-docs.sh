#!/usr/bin/env bash
# Fail if any fenced code block is missing a language (markdownlint MD040).
#
# Kept as a self-contained shell check rather than pulling in markdownlint so CI
# needs no node toolchain for a rule this repo only has one of.
#
# The parser is STATEFUL, and has to be. A previous version just counted lines
# equal to exactly "```" and took odd ones to be openers. That anchored to
# column 0, so it silently skipped every INDENTED fence -- and CommonMark allows
# up to three leading spaces. Three genuinely unlabelled fences (inside list
# items in PROTOCOL.md and VENDOR-DRIVER.md) sailed past it while the script
# printed "all fenced code blocks are labelled". A check that reports success
# over the failure it exists to catch is worse than no check.
#
# Handled now: up to 3 leading spaces; both ``` and ~~~; runs longer than three;
# closing fences (same char, at least as long, no info string); nested-looking
# markers inside a block, which are content, not fences; and a block left open
# at end of file.
#
# With no arguments, checks every tracked *.md. Given file arguments, checks
# exactly those -- which is what makes the parser itself testable against
# fixtures instead of only ever being pointed at this repo.
set -euo pipefail

if [ "$#" -gt 0 ]; then
  files() { printf '%s\n' "$@"; }
else
  cd "$(dirname "$0")/.."
  files() { git ls-files '*.md'; }
fi

bad=0
while IFS= read -r f; do
  awk -v F="$f" '
    function trim(s){ gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      line = $0
      n = 0
      while (substr(line, n+1, 1) == " ") n++
      if (n > 3) next                      # 4+ spaces is an indented code block
      body = substr(line, n+1)
      ch = substr(body, 1, 1)
      if (ch != "`" && ch != "~") next
      run = 0
      while (substr(body, run+1, 1) == ch) run++
      if (run < 3) next
      info = trim(substr(body, run+1))
      if (!infence) {
        infence = 1; fch = ch; frun = run; fline = NR
        # a backtick fence info string may not itself contain a backtick
        if (info == "" || (ch == "`" && index(info, "`") > 0)) {
          print F ":" NR ": fenced code block has no language (MD040)"
          rc = 1
        }
      } else if (ch == fch && run >= frun && info == "") {
        infence = 0                        # valid closing fence
      }
    }
    END {
      if (infence) { print F ":" fline ": fenced code block is never closed"; rc = 1 }
      exit rc+0
    }
  ' "$f" || bad=1
done < <(files "$@")

if [ "$bad" = 0 ]; then
  echo "docs: all fenced code blocks are labelled"
else
  exit 1
fi
