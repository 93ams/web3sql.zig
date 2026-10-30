#!/bin/sh
# Lists PRD requirement ids (REQ-*) that no test name mentions. Exit 1 if any are uncovered.
cd "$(dirname "$0")/.." || exit 1
missing=0
for id in $(grep -o 'REQ-[A-Z0-9]*-[0-9]*' prd.md | sort -u); do
  if ! grep -rqE "^test \"[^\"]*$id" src; then
    echo "uncovered: $id"
    missing=1
  fi
done
exit $missing
