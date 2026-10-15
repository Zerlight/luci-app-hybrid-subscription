#!/bin/sh
set -eu
CURRENT=$(uci -q get openclash.config.config_path || true)
case "$CURRENT" in *'/HybridSubscriptions-'*.yaml) echo 'Switch OpenClash to another configuration before uninstalling.' >&2; exit 1;; esac
/etc/init.d/hybrid-subscription stop
/etc/init.d/hybrid-subscription disable
# Remove only our marked hook block, preserving any other OpenClash customization.
/usr/bin/ruby -e 'p="/etc/openclash/custom/openclash_custom_overwrite.sh"; if File.file?(p); s=File.read(p); s=s.gsub(/^# BEGIN hybrid-subscription managed profiles\n.*?^# END hybrid-subscription managed profiles\n/m, ""); File.write(p,s); end'
rm -f /usr/libexec/rpcd/luci.hybrid_subscription /www/cgi-bin/hybrid-subscription /etc/init.d/hybrid-subscription /www/luci-static/resources/hybrid-subscription.js /usr/share/luci/menu.d/luci-app-hybrid-subscription.json /usr/share/rpcd/acl.d/luci-app-hybrid-subscription.json /usr/lib/lua/luci/i18n/hybrid-subscription.*.lmo
rm -rf /usr/share/hybrid-subscription /www/luci-static/resources/view/hybrid-subscription
/etc/init.d/rpcd restart
rm -f /tmp/luci-indexcache.* /tmp/luci-indexcache
printf 'Application removed. Private state retained in /etc/hybrid-subscription for recovery.\n'
