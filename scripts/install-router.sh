#!/bin/sh
# Run on the router after extracting the repository into a temporary directory.
set -eu
HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
[ "$(id -u)" = 0 ] || { echo 'Run as root on OpenWrt.' >&2; exit 1; }
/usr/bin/ruby -e '%w[json yaml digest open3 fileutils uri timeout ipaddr socket].each { |m| require m }'
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/root/hybrid-subscription-install-$STAMP
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
(cd "$HERE/root" && find . -type f | sed 's#^./##') > "$BACKUP/files.txt"
(cd "$HERE/htdocs" && find . -type f | sed 's#^./#www/#') >> "$BACKUP/files.txt"
: > "$BACKUP/existing.txt"
while IFS= read -r name; do [ ! -e "/$name" ] || echo "$name" >> "$BACKUP/existing.txt"; done < "$BACKUP/files.txt"
if [ -s "$BACKUP/existing.txt" ]; then tar -czf "$BACKUP/before.tgz" -C / -T "$BACKUP/existing.txt"; fi
if [ -d /etc/hybrid-subscription ]; then tar -czf "$BACKUP/state.tgz" -C / etc/hybrid-subscription; fi
(cd "$HERE/root" && find . -type f | tar -cf - -T -) | tar -xf - -C /
(cd "$HERE/htdocs" && find . -type f | tar -cf - -T -) | tar -xf - -C /www
if command -v po2lmo >/dev/null 2>&1 && [ -d "$HERE/po" ]; then
 mkdir -p /usr/lib/lua/luci/i18n
 for po_file in "$HERE"/po/*/*.po; do
  [ -f "$po_file" ] || continue
  lang_dir=$(basename "$(dirname "$po_file")")
  case "$lang_dir" in
   templates) continue ;;
   zh_Hans|zh-cn) lmo_lang="zh-cn" ;;
   zh_Hant|zh-tw) lmo_lang="zh-tw" ;;
   *) lmo_lang=$(printf '%s' "$lang_dir" | tr '[:upper:]_' '[:lower:]-') ;;
  esac
  lmo_target="/usr/lib/lua/luci/i18n/hybrid-subscription.$lmo_lang.lmo"
  po2lmo "$po_file" "$lmo_target"
  chmod 644 "$lmo_target"
  printf '%s\n' "${lmo_target#/}" >> "$BACKUP/files.txt"
 done
fi
while IFS= read -r name; do chown 0:0 "/$name"; done < "$BACKUP/files.txt"
chmod 755 /usr/libexec/rpcd/luci.hybrid_subscription /www/cgi-bin/hybrid-subscription /etc/init.d/hybrid-subscription
/usr/bin/ruby /usr/share/hybrid-subscription/cli.rb init
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache.* /tmp/luci-indexcache
# LuCI keys browser JS caches by the package database mtime. Development installs
# bypass apk/opkg, so advance that stamp without changing database contents.
if [ -f /lib/apk/db/installed ]; then touch /lib/apk/db/installed;
elif [ -f /usr/lib/opkg/status ]; then touch /usr/lib/opkg/status; fi
/etc/init.d/hybrid-subscription enable
if /etc/init.d/hybrid-subscription running; then
 /etc/init.d/hybrid-subscription restart
else
 /etc/init.d/hybrid-subscription start
fi
# rpcd loads executable plugins asynchronously after restart.
i=0
while ! ubus list luci.hybrid_subscription 2>/dev/null | grep -q luci.hybrid_subscription; do
 i=$((i + 1))
 [ "$i" -lt 10 ] || { echo "RPC registration failed; inspect logread." >&2; exit 1; }
 sleep 1
done
printf 'Installed. File backup: %s\n' "$BACKUP"
