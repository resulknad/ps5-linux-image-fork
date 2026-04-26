#!/bin/sh
set -e
BOOT=/boot/efi
kexec -l "$BOOT/bzImage" --initrd="$BOOT/initrd.img" --command-line="$(cat $BOOT/cmdline.txt)"
kexec -e
