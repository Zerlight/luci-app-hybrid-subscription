include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Hybrid Subscription Manager
LUCI_DEPENDS:=+luci-base +luci-lib-uqr +rpcd +curl +ruby +ruby-json +ruby-yaml +ruby-digest +ruby-open3 +ruby-fileutils +ruby-uri +ruby-timeout +ruby-ipaddr +ruby-socket
LUCI_PKGARCH:=all
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

include ../../luci.mk
