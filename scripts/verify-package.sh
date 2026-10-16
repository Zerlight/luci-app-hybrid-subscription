#!/bin/bash
# Inspect SDK outputs without installing them or running package scripts.
set -euo pipefail
format=$1
package_file=$(realpath "$2")
name=$3
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
mkdir "$temporary/root"
case "$format" in
 ipk)
  tar -xzf "$package_file" -C "$temporary"
  tar -xzf "$temporary/data.tar.gz" -C "$temporary/root"
  mkdir "$temporary/control"
  tar -xzf "$temporary/control.tar.gz" -C "$temporary/control"
  grep -qx "Package: $name" "$temporary/control/control"
  grep -qx 'Architecture: all' "$temporary/control/control"
  ;;
 apk)
  staging_dir/host/bin/apk --allow-untrusted extract \
   --destination "$temporary/root" --no-chown "$package_file"
  staging_dir/host/bin/apk adbdump --format json "$package_file" > "$temporary/metadata.json"
  python3 - "$temporary/metadata.json" "$name" <<'PY'
import json, sys
def objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from objects(child)
data = json.load(open(sys.argv[1]))
assert any(obj.get('name') == sys.argv[2] and obj.get('arch') == 'noarch' for obj in objects(data)), 'Package name/architecture mismatch'
PY
  ;;
 *) exit 2 ;;
esac
if [[ "$name" == luci-app-hybrid-subscription ]]; then
 for file in /usr/share/hybrid-subscription/{backend,engine,cli,quota,regions,openclash,converter,compatibility,download}.rb \
             /usr/share/hybrid-subscription/{LICENSE,NOTICE} \
             /www/luci-static/resources/hybrid-subscription.js \
             /www/luci-static/resources/view/hybrid-subscription/{overview,sources,profiles,rules,compatibility,settings}.js \
             /usr/share/luci/menu.d/luci-app-hybrid-subscription.json \
             /usr/share/rpcd/acl.d/luci-app-hybrid-subscription.json; do
  test -s "$temporary/root$file"
 done
 for file in /usr/libexec/rpcd/luci.hybrid_subscription /www/cgi-bin/hybrid-subscription /etc/init.d/hybrid-subscription; do
  test -x "$temporary/root$file"
 done
else
 test -s "$temporary/root/usr/lib/lua/luci/i18n/hybrid-subscription.zh-cn.lmo"
fi
printf 'Verified %s (%s)\n' "$name" "$format"
