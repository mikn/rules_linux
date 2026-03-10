"""Named composable exclusion profiles for initrd stripping."""

# Documentation, localization, package management
_STRIP_DOCS = [
    "--exclude=./usr/share/doc/*",
    "--exclude=./usr/share/man/*",
    "--exclude=./usr/share/info/*",
    "--exclude=./usr/share/gtk-doc/*",
]

_STRIP_LOCALES = [
    "--exclude=./usr/share/locale/*",
    "--exclude=./usr/share/i18n/*",
    "--exclude=./usr/lib/locale/*",
    "--exclude=./usr/lib/systemd/catalog/*.*.catalog",
]

_STRIP_PKG_MGMT = [
    "--exclude=./var/cache/apt/*",
    "--exclude=./var/cache/debconf/*",
    "--exclude=./var/lib/apt/lists/*",
    "--exclude=./var/log/*",
]

_STRIP_DEV = [
    "--exclude=./usr/include/*",
    "--exclude=./usr/share/aclocal/*",
    "--exclude=./usr/lib/*.a",
    "--exclude=./usr/lib/*.la",
]

_STRIP_SCRIPTING = [
    "--exclude=./usr/bin/python*",
    "--exclude=./usr/share/perl*",
    "--exclude=./usr/lib/python*",
    "--exclude=./usr/share/python*",
    "--exclude=*.pyc",
    "--exclude=*__pycache__*",
    "--exclude=./usr/bin/perl*",
    "--exclude=./usr/lib/*/perl*",
]

_STRIP_MISC = [
    "--exclude=./usr/share/lintian/*",
    "--exclude=./usr/share/linda/*",
    "--exclude=./usr/share/bug/*",
    "--exclude=./usr/share/menu/*",
    "--exclude=./usr/share/applications/*",
    "--exclude=./usr/share/pixmaps/*",
    "--exclude=./usr/share/sounds/*",
    "--exclude=*.pod",
    "--exclude=./usr/share/zsh/*",
    "--exclude=./usr/share/fish/*",
    "--exclude=./usr/share/bash-completion/*",
    "--exclude=./usr/share/common-licenses/*",
    "--exclude=./usr/share/metainfo/*",
    "--exclude=./usr/share/initramfs-tools/*",
    "--exclude=./usr/share/gcc/*",
    "--exclude=./usr/share/polkit-1/*",
    "--exclude=./usr/share/pam/*",
    "--exclude=./usr/share/xfsprogs/*",
    "--exclude=./usr/share/dpkg/*",
    "--exclude=./usr/share/debconf/*",
    "--exclude=./usr/share/doc-base/*",
    "--exclude=./usr/share/debianutils/*",
    "--exclude=./usr/share/util-linux/*",
    "--exclude=./usr/share/sensible-utils/*",
    "--exclude=./usr/share/readline/*",
    "--exclude=./usr/share/libc-bin/*",
    "--exclude=./usr/share/gdb/*",
    "--exclude=./usr/share/binfmts/*",
    "--exclude=./usr/share/base-files/*",
    "--exclude=./usr/share/pam-configs/*",
    "--exclude=./usr/share/libgcrypt20/*",
    "--exclude=./usr/share/pkgconfig/*",
    "--exclude=./usr/share/ca-certificates/*",
    "--exclude=./boot/*",
]

# Desktop/consumer hardware drivers
_STRIP_DESKTOP_DRIVERS = [
    "--exclude=./lib/modules/*/kernel/arch/x86/kvm/*",
    "--exclude=./lib/modules/*/kernel/sound/*",
    "--exclude=./lib/modules/*/kernel/drivers/gpu/*",
    "--exclude=./lib/modules/*/kernel/drivers/media/*",
    "--exclude=./lib/modules/*/kernel/drivers/staging/*",
    "--exclude=./lib/modules/*/kernel/drivers/usb/serial/*",
    "--exclude=./lib/modules/*/kernel/drivers/usb/gadget/*",
    "--exclude=./lib/modules/*/kernel/drivers/usb/misc/*",
    "--exclude=./lib/modules/*/kernel/drivers/bluetooth/*",
    "--exclude=./lib/modules/*/kernel/drivers/infiniband/*",
    "--exclude=./lib/modules/*/kernel/drivers/isdn/*",
    "--exclude=./lib/modules/*/kernel/drivers/wireless/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/wireless/*",
    "--exclude=./lib/modules/*/kernel/net/wireless/*",
    "--exclude=./lib/modules/*/kernel/drivers/input/*",
    "--exclude=./lib/modules/*/kernel/drivers/hid/*",
    "--exclude=./lib/modules/*/kernel/drivers/iio/*",
    "--exclude=./lib/modules/*/kernel/drivers/comedi/*",
    "--exclude=./lib/modules/*/kernel/drivers/mtd/*",
    "--exclude=./lib/modules/*/kernel/drivers/video/*",
    "--exclude=./lib/modules/*/kernel/drivers/mmc/*",
    "--exclude=./lib/modules/*/kernel/drivers/thunderbolt/*",
    "--exclude=./lib/modules/*/kernel/drivers/firewire/*",
    "--exclude=./lib/modules/*/kernel/drivers/pcmcia/*",
    "--exclude=./lib/modules/*/kernel/drivers/android/*",
    "--exclude=./lib/modules/*/kernel/drivers/nfc/*",
    "--exclude=./lib/modules/*/kernel/drivers/memstick/*",
    "--exclude=./lib/modules/*/kernel/drivers/accessibility/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/usb/*",
    "--exclude=./lib/modules/*/kernel/drivers/power/*",
    "--exclude=./lib/modules/*/kernel/drivers/mfd/*",
    "--exclude=./lib/modules/*/kernel/net/6lowpan/*",
    "--exclude=./lib/modules/*/kernel/net/sched/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/phy/*",
]

# Niche NIC drivers
_STRIP_NICHE_NIC = [
    "--exclude=./lib/modules/*/kernel/drivers/net/arcnet/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/fddi/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/hamradio/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/wan/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ppp/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/slip/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/wwan/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ieee802154/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/3com/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/8390/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/adaptec/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/aeroflex/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/agere/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/alteon/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/amd/lance.ko",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/amd/pcnet32.ko",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/apple/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/arc/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/atheros/atlx/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/atheros/atl1c/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/atheros/atl1e/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/broadcom/b44.ko",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/broadcom/bcm63xx_enet.ko",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/cadence/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/cavium/liquidio/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/chelsio/cxgb/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/chelsio/cxgb3/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/cirrus/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/cisco/enic/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/davicom/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/dec/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/dlink/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/emulex/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/fujitsu/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/hpe/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/hp/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/ibm/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/micrel/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/myricom/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/natsemi/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/neterion/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/nvidia/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/oki-semi/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/packetengines/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/realtek/8139cp.ko",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/realtek/8139too.ko",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/rdc/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/renesas/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/rocker/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/samsung/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/seeq/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/silan/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/sis/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/smsc/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/sun/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/synopsys/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/tehuti/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/ti/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/via/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/wiznet/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/xircom/*",
    "--exclude=./lib/modules/*/kernel/drivers/net/ethernet/xilinx/*",
]

# Niche filesystem modules
_STRIP_NICHE_FS = [
    "--exclude=./lib/modules/*/kernel/fs/9p/*",
    "--exclude=./lib/modules/*/kernel/fs/adfs/*",
    "--exclude=./lib/modules/*/kernel/fs/affs/*",
    "--exclude=./lib/modules/*/kernel/fs/afs/*",
    "--exclude=./lib/modules/*/kernel/fs/befs/*",
    "--exclude=./lib/modules/*/kernel/fs/bfs/*",
    "--exclude=./lib/modules/*/kernel/fs/btrfs/*",
    "--exclude=./lib/modules/*/kernel/fs/ceph/*",
    "--exclude=./lib/modules/*/kernel/fs/cifs/*",
    "--exclude=./lib/modules/*/kernel/fs/coda/*",
    "--exclude=./lib/modules/*/kernel/fs/cramfs/*",
    "--exclude=./lib/modules/*/kernel/fs/dlm/*",
    "--exclude=./lib/modules/*/kernel/fs/ecryptfs/*",
    "--exclude=./lib/modules/*/kernel/fs/efs/*",
    "--exclude=./lib/modules/*/kernel/fs/erofs/*",
    "--exclude=./lib/modules/*/kernel/fs/exofs/*",
    "--exclude=./lib/modules/*/kernel/fs/f2fs/*",
    "--exclude=./lib/modules/*/kernel/fs/freevxfs/*",
    "--exclude=./lib/modules/*/kernel/fs/fuse/*",
    "--exclude=./lib/modules/*/kernel/fs/gfs2/*",
    "--exclude=./lib/modules/*/kernel/fs/hfs/*",
    "--exclude=./lib/modules/*/kernel/fs/hfsplus/*",
    "--exclude=./lib/modules/*/kernel/fs/hpfs/*",
    "--exclude=./lib/modules/*/kernel/fs/jffs2/*",
    "--exclude=./lib/modules/*/kernel/fs/jfs/*",
    "--exclude=./lib/modules/*/kernel/fs/minix/*",
    "--exclude=./lib/modules/*/kernel/fs/nfs/*",
    "--exclude=./lib/modules/*/kernel/fs/nfsd/*",
    "--exclude=./lib/modules/*/kernel/fs/nilfs2/*",
    "--exclude=./lib/modules/*/kernel/fs/nls/*",
    "--exclude=./lib/modules/*/kernel/fs/ntfs/*",
    "--exclude=./lib/modules/*/kernel/fs/ntfs3/*",
    "--exclude=./lib/modules/*/kernel/fs/ocfs2/*",
    "--exclude=./lib/modules/*/kernel/fs/omfs/*",
    "--exclude=./lib/modules/*/kernel/fs/orangefs/*",
    "--exclude=./lib/modules/*/kernel/fs/qnx4/*",
    "--exclude=./lib/modules/*/kernel/fs/qnx6/*",
    "--exclude=./lib/modules/*/kernel/fs/reiserfs/*",
    "--exclude=./lib/modules/*/kernel/fs/romfs/*",
    "--exclude=./lib/modules/*/kernel/fs/smb/*",
    "--exclude=./lib/modules/*/kernel/fs/squashfs/*",
    "--exclude=./lib/modules/*/kernel/fs/sysv/*",
    "--exclude=./lib/modules/*/kernel/fs/ubifs/*",
    "--exclude=./lib/modules/*/kernel/fs/udf/*",
    "--exclude=./lib/modules/*/kernel/fs/ufs/*",
    "--exclude=./lib/modules/*/kernel/fs/zonefs/*",
]

# Niche network protocols
_STRIP_NICHE_NET = [
    "--exclude=./lib/modules/*/kernel/net/802/*",
    "--exclude=./lib/modules/*/kernel/net/9p/*",
    "--exclude=./lib/modules/*/kernel/net/appletalk/*",
    "--exclude=./lib/modules/*/kernel/net/atm/*",
    "--exclude=./lib/modules/*/kernel/net/ax25/*",
    "--exclude=./lib/modules/*/kernel/net/batman-adv/*",
    "--exclude=./lib/modules/*/kernel/net/bluetooth/*",
    "--exclude=./lib/modules/*/kernel/net/can/*",
    "--exclude=./lib/modules/*/kernel/net/ceph/*",
    "--exclude=./lib/modules/*/kernel/net/dccp/*",
    "--exclude=./lib/modules/*/kernel/net/decnet/*",
    "--exclude=./lib/modules/*/kernel/net/ieee802154/*",
    "--exclude=./lib/modules/*/kernel/net/ife/*",
    "--exclude=./lib/modules/*/kernel/net/ipx/*",
    "--exclude=./lib/modules/*/kernel/net/lapb/*",
    "--exclude=./lib/modules/*/kernel/net/llc/*",
    "--exclude=./lib/modules/*/kernel/net/mac80211/*",
    "--exclude=./lib/modules/*/kernel/net/mac802154/*",
    "--exclude=./lib/modules/*/kernel/net/mpls/*",
    "--exclude=./lib/modules/*/kernel/net/ncsi/*",
    "--exclude=./lib/modules/*/kernel/net/netrom/*",
    "--exclude=./lib/modules/*/kernel/net/nfc/*",
    "--exclude=./lib/modules/*/kernel/net/phonet/*",
    "--exclude=./lib/modules/*/kernel/net/psample/*",
    "--exclude=./lib/modules/*/kernel/net/rds/*",
    "--exclude=./lib/modules/*/kernel/net/rose/*",
    "--exclude=./lib/modules/*/kernel/net/rxrpc/*",
    "--exclude=./lib/modules/*/kernel/net/sctp/*",
    "--exclude=./lib/modules/*/kernel/net/smc/*",
    "--exclude=./lib/modules/*/kernel/net/sunrpc/*",
    "--exclude=./lib/modules/*/kernel/net/tipc/*",
    "--exclude=./lib/modules/*/kernel/net/x25/*",
]

# Firmware for consumer devices
_STRIP_FIRMWARE = [
    "--exclude=./lib/firmware/i915/*",
    "--exclude=./lib/firmware/nvidia/*",
    "--exclude=./lib/firmware/mediatek/*",
    "--exclude=./lib/firmware/rtw89/*",
    "--exclude=./lib/firmware/rtlwifi/*",
    "--exclude=./lib/firmware/rtw88/*",
    "--exclude=./lib/firmware/rtl_bt/*",
    "--exclude=./lib/firmware/dvb-*",
    "--exclude=./lib/firmware/v4l-*",
    "--exclude=./lib/firmware/*usb*",
    "--exclude=./lib/firmware/go7007/*",
]

# Composed profiles

STRIP_PROFILE_NONE = []

STRIP_PROFILE_SERVER = (
    _STRIP_DOCS +
    _STRIP_LOCALES +
    _STRIP_PKG_MGMT +
    _STRIP_DEV +
    _STRIP_SCRIPTING +
    _STRIP_MISC +
    _STRIP_DESKTOP_DRIVERS +
    _STRIP_NICHE_NIC +
    _STRIP_NICHE_FS +
    _STRIP_NICHE_NET +
    _STRIP_FIRMWARE
)

STRIP_PROFILE_MINIMAL = STRIP_PROFILE_SERVER + [
    "--exclude=./usr/lib/x86_64-linux-gnu/gconv/*",
    "--exclude=./usr/lib/x86_64-linux-gnu/libicudata.so*",
    "--exclude=./usr/lib/klibc/*",
]
