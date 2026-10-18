include $(TOPDIR)/rules.mk

PKG_NAME:=usteer
PKG_VERSION:=2026.10.18.25.12.5
PKG_RELEASE:=1

PKG_SOURCE:=usteer-2026.10.18.25.12.5-r1.apk
PKG_SOURCE_URL:=https://github.com/AndreaCovelli/usteer-apk-builder/releases/download/usteer-2026.10.18.25.12.5-r1
PKG_HASH:=6e7b172a5a36ce52c280a18c6074808904b1697f972c1c9d42f633f99b49e555
PKG_BUILD_DEPENDS:=apk/host

include $(INCLUDE_DIR)/package.mk

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(DL_DIR)/$(PKG_SOURCE) $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/usteer
  SECTION:=net
  CATEGORY:=Network
  DEPENDS:=+libubox +libubus +libblobmsg-json +libnl-tiny
  TITLE:=OpenWrt AP roaming assist daemon
endef

define Package/usteer/conffiles
/etc/config/usteer
endef

define Package/usteer/install
	$(STAGING_DIR_HOST)/bin/apk extract --allow-untrusted --no-chown --destination $(1) $(PKG_BUILD_DIR)/$(PKG_SOURCE)
endef

$(eval $(call BuildPackage,usteer))
