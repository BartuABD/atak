#
# atak-autostart - installs /etc/init.d/atak-autostart (sysvinit, start 99 in runlevels 2-5).
# It mounts the SD card and runs /mnt/sd/atak_boot.sh, so the A.T.A.K. station starts without a PC.
# Also installs fixed SSH host keys in /etc/ssh (made once by mk_hostkeys.sh): the rootfs is in RAM, so without them
# sshd makes new keys at every boot and the PC warns "host key changed".
#

SUMMARY = "A.T.A.K. standalone start script"
SECTION = "PETALINUX/apps"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://atak-autostart \
	file://ssh_host_rsa_key file://ssh_host_rsa_key.pub \
	file://ssh_host_ecdsa_key file://ssh_host_ecdsa_key.pub \
	file://ssh_host_ed25519_key file://ssh_host_ed25519_key.pub \
	"

S = "${WORKDIR}"

inherit update-rc.d

INITSCRIPT_NAME = "atak-autostart"
INITSCRIPT_PARAMS = "defaults 99"

do_install() {
	install -d ${D}${sysconfdir}/init.d
	install -m 0755 ${S}/atak-autostart ${D}${sysconfdir}/init.d/atak-autostart
	install -d ${D}${sysconfdir}/ssh
	for t in rsa ecdsa ed25519; do
		install -m 0600 ${S}/ssh_host_${t}_key ${D}${sysconfdir}/ssh/ssh_host_${t}_key
		install -m 0644 ${S}/ssh_host_${t}_key.pub ${D}${sysconfdir}/ssh/ssh_host_${t}_key.pub
	done
}

FILES:${PN} += "${sysconfdir}/init.d/atak-autostart ${sysconfdir}/ssh/ssh_host_*"
