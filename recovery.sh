#!/bin/bash
set -e
err_report() {
  echo "Error at $BASH_SOURCE on line $1!"
}
trap 'err_report $LINENO' ERR

if [[ "$EUID" != "0" ]]; then
  echo "Must be run as root!"
  exit 1
fi

# Setup /dev/md0 if it hasn't been setup already
if [[ ! -b /dev/md0 ]]; then
  ./create_raid_array
fi

# -boot d to boot into the CDROM by default
qemu-system-x86_64 \
  -bios /usr/share/ovmf/OVMF.fd \
  -boot d \
  -drive file=/dev/md0,media=disk,format=raw \
  -cpu host -smp 6,sockets=1,cores=3,threads=2 -enable-kvm \
  -m 8G \
  -cdrom ./win10.iso -msg timestamp=on
