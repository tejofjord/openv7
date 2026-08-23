#!/usr/bin/env bash
# Fixture tests for tools/check-docs.sh.
#
# These exist because the first version of that checker anchored to column 0 and
# reported "all fenced code blocks are labelled" while three genuinely unlabelled
# indented fences sat in docs/. A linter that passes over the thing it guards is
# worse than none, so the parser now has cases pinned to it.
#
# Run: tools/check-docs-test.sh
set -u
CHECK="$(cd "$(dirname "$0")" && pwd)/check-docs.sh"
D=$(mktemp -d); cd "$D"
pass=0; fail=0
t(){
  name=$1; want=$2
  printf '%s' "$3" > case.md
  if bash "$CHECK" case.md >/dev/null 2>&1; then got=ok; else got=flag; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass+1)); printf '  ok   %-44s -> %s\n' "$name" "$got"
  else
    fail=$((fail+1)); printf '  FAIL %-44s -> %s (want %s)\n' "$name" "$got" "$want"
  fi
}
B='```'; B4='````'; T='~~~'
t "labelled fence"                      ok   "${B}text
hi
${B}
"
t "UNLABELLED fence"                    flag "${B}
hi
${B}
"
t "2-space indent, unlabelled"          flag "- item

  ${B}
  hi
  ${B}
"
t "3-space indent, unlabelled"          flag "1. item

   ${B}
   hi
   ${B}
"
t "3-space indent, labelled"            ok   "1. item

   ${B}text
   hi
   ${B}
"
t "4-space indent is a code block"      ok   "    ${B}
    not a fence
"
t "tilde fence, unlabelled"             flag "${T}
hi
${T}
"
t "tilde fence, labelled"               ok   "${T}text
hi
${T}
"
t "4-backtick run, unlabelled"          flag "${B4}
hi
${B4}
"
t "4-backtick run, labelled"            ok   "${B4}text
hi
${B4}
"
t "inner ticks are CONTENT not a fence" ok   "${B4}text
${B}
${B4}
"
t "unterminated fence"                  flag "${B}text
hi
"
# If ~~~ wrongly closed the backtick fence, the trailing ``` would open a NEW
# unlabelled fence that is never closed -- two flags. Clean proves it did not.
t "tilde does not close a backtick fence" ok "${B}text
${T}
${B}
"
# The converse, which genuinely IS a violation:
t "flags a later unlabelled fence"        flag "${B}text
hi
${B}

${B}
oops
${B}
"
echo; echo "  passed=$pass failed=$fail"
cd /; rm -rf "$D"
[ "$fail" = 0 ]
