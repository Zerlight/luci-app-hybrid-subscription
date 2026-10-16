include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Hybrid Subscription Manager
LUCI_DEPENDS:=+luci-base +luci-lib-uqr +rpcd +curl +ruby +ruby-json +ruby-yaml +ruby-digest +ruby-open3 +ruby-fileutils +ruby-uri +ruby-timeout +ruby-ipaddr +ruby-socket
LUCI_PKGARCH:=all
PKG_VERSION:=0.3.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

define Build/Prepare/luci-app-hybrid-subscription
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/share/hybrid-subscription
	$(INSTALL_DATA) ./LICENSE ./NOTICE $(PKG_BUILD_DIR)/root/usr/share/hybrid-subscription/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
