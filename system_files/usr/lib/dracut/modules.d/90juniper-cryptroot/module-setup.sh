#!/usr/bin/bash
# Juniper: LUKS2 root bound to the Pi's OTP key (issue #50). Logic: /usr/libexec/juniper/cryptroot.
# shellcheck disable=SC2154 # moddir, initdir, systemdsystemunitdir: set by dracut
check() {
  require_binaries cryptsetup rpi-fw-crypto age sfdisk partx blkid || return 1
  return 0
}
depends() { echo dm systemd; }
# aes-arm64/aes_generic: the single-block AES that Adiantum needs on a Pi 4 (no AES
# instructions, so aes-ce-cipher won't load); today they come in only through `crypt`.
installkernel() {
  hostonly='' instmods dm_mod dm_crypt af_alg algif_skcipher adiantum chacha_generic chacha-neon \
    nhpoly1305 nhpoly1305-neon poly1305-neon aes-ce-blk aes-ce-cipher aes-neon-bs aes-arm64 aes_generic
}
# env: cryptroot and fwkey start with `#!/usr/bin/env bash`.
install() {
  inst_multiple cryptsetup rpi-fw-crypto age sfdisk partx blkid mount umount mkdir cat grep sed \
    head tr od cut readlink sync mv sleep basename modprobe env
  inst_simple /usr/libexec/juniper/cryptroot
  inst_simple /usr/libexec/juniper/fwkey
  inst_simple "$moddir/juniper-cryptroot-prepare.service" "$systemdsystemunitdir/juniper-cryptroot-prepare.service"
  inst_simple "$moddir/juniper-cryptroot-unlock.service" "$systemdsystemunitdir/juniper-cryptroot-unlock.service"
  $SYSTEMCTL -q --root "$initdir" add-wants sysinit.target juniper-cryptroot-prepare.service
  $SYSTEMCTL -q --root "$initdir" add-wants initrd.target juniper-cryptroot-unlock.service
}
