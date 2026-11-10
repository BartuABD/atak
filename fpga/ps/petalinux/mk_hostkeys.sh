#!/bin/bash
# mk_hostkeys.sh - makes the board's fixed SSH host keys once, in the atak-autostart recipe (files/ssh_host_*).
# The rootfs runs from RAM, so without fixed keys sshd makes new ones at every boot ("host key changed").
# The keys are private: they are git-ignored and must never be committed.
cd "$(dirname "$0")/project-spec/meta-user/recipes-apps/atak-autostart/files" || exit 1
for t in rsa ecdsa ed25519; do
    [ -f ssh_host_${t}_key ] || ssh-keygen -q -t $t -N '' -C zybo-atak -f ssh_host_${t}_key
done
ssh-keygen -lf ssh_host_ed25519_key.pub
