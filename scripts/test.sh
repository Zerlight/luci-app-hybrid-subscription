#!/bin/sh
set -eu
cd "$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

for suite in tests/test_*.rb; do
 ruby "$suite"
done
node tests/frontend_test.js
node tests/workbench_test.js
for catalog in po/*/*.po po/templates/*.pot; do
 msgfmt --check-format -o /dev/null "$catalog"
done
for script in scripts/*.sh root/etc/init.d/*; do
 case "$(head -n 1 "$script")" in
  *bash*) bash -n "$script" ;;
  *) sh -n "$script" ;;
 esac
done
git diff --check
