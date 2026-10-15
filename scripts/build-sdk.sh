#!/bin/bash
# Run inside the official OpenWrt SDK container, with /src and /artifacts mounted.
set -euo pipefail
source_dir=${SOURCE_DIR:-/src}
output_dir=${OUTPUT_DIR:-/artifacts}
format=${PACKAGE_FORMAT:?Set PACKAGE_FORMAT to ipk or apk}
case "$format" in ipk|apk) ;; *) exit 2 ;; esac

# Release SDK images include the SDK; snapshot images download it here.
if [[ ! -f include/toplevel.mk ]]; then bash setup.sh; fi
sed -e 's,https://git.openwrt.org/feed/,https://github.com/openwrt/,' \
    -e 's,https://git.openwrt.org/openwrt/,https://github.com/openwrt/,' \
    -e 's,https://git.openwrt.org/project/,https://github.com/openwrt/,' \
    feeds.conf.default > feeds.conf
./scripts/feeds update base packages luci
./scripts/feeds install luci-base luci-lib-uqr ruby curl rpcd

package=luci-app-hybrid-subscription
mkdir -p "package/$package"
cp -a "$source_dir"/Makefile "$source_dir"/LICENSE "$source_dir"/NOTICE \
      "$source_dir"/htdocs "$source_dir"/root "$source_dir"/po "package/$package/"
touch .config
for key in ALL ALL_NONSHARED ALL_KMODS RUBY_ENABLE_YJIT "PACKAGE_$package" \
           LUCI_LANG_zh_Hans PACKAGE_luci-i18n-hybrid-subscription-zh-cn; do
 sed -i "/^CONFIG_$key=/d; /^# CONFIG_$key is not set$/d" .config
done
cat >> .config <<'CONFIG'
# CONFIG_ALL is not set
# CONFIG_ALL_NONSHARED is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_RUBY_ENABLE_YJIT is not set
CONFIG_PACKAGE_luci-app-hybrid-subscription=m
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-i18n-hybrid-subscription-zh-cn=m
CONFIG
make defconfig 2>&1 | tee /tmp/hybrid-defconfig.log
if grep -q 'error: recursive dependency' /tmp/hybrid-defconfig.log; then
 awk '/^[[:space:]]*(menu)?config PACKAGE_libcurl$/{printing=1} printing {print} printing && /^[[:space:]]*(menu)?config / && $2 != "PACKAGE_libcurl" {exit}' tmp/.config-package.in
 sed -n '/^config LIBCURL_LDAP$/,/^$/p' Config-build.in
 exit 1
fi
make -j"$(nproc)" "package/$package/compile" V=s

mkdir -p "$output_dir"
for name in "$package" luci-i18n-hybrid-subscription-zh-cn; do
 mapfile -t files < <(find bin/packages -type f -name "$name"'_*.'"$format" -o -type f -name "$name"'-*.'"$format")
 if [[ ${#files[@]} -ne 1 || ! -s ${files[0]} ]]; then
  printf 'Expected exactly one non-empty %s package for %s\n' "$format" "$name" >&2
  exit 1
 fi
 bash "$source_dir/scripts/verify-package.sh" "$format" "${files[0]}" "$name"
 cp "${files[0]}" "$output_dir/"
done
cd "$output_dir"
sha256sum -- *."$format" > SHA256SUMS
