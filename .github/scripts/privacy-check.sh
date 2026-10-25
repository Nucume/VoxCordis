#!/usr/bin/env bash
# Fails if any word in PRIVATE_NAMES (comma-separated) shows up in the files,
# in any earlier version of any file, or in any commit's author, committer or
# message. The words live in a
# secret so the check never writes them into the repo. Needs full history
# (actions/checkout with fetch-depth: 0).
set -euo pipefail
names="${RUNNER_TEMP:-/tmp}/private-names"
printf '%s' "$PRIVATE_NAMES" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' > "$names"
found=0
if git grep -I -i -l -F -f "$names"; then found=1; fi
# Every version of every file, so a name that was removed later (but would
# still be public in the history) counts too. Prints commit:path only.
old=$(git rev-list --all | xargs -r -n 100 git grep -I -i -l -F -f "$names" 2>/dev/null || true)
if [ -n "$old" ]; then
  echo "A private name appears in an earlier version of:"; echo "$old" | sort -u | head -50; found=1
fi
if git log --format='%an %ae %cn %ce %B' | grep -i -q -F -f "$names"; then
  echo "A private name appears in the commit history."; found=1
fi
rm -f "$names"
if [ "$found" = 1 ]; then echo "::error::Private name found (see above)"; exit 1; fi
echo "No private names found."
