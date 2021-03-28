#!/bin/bash
set -e
err_report() {
  echo "Error at $BASH_SOURCE on line $1!"
}
trap 'err_report $LINENO' ERR

# If not already run as sudo, then run as sudo
if [[ "$EUID" != "0" ]]; then
  sudo "$BASH_SOURCE" "$@"
  exit 0
fi
cd "$(dirname $([ -L "$BASH_SOURCE" ] && readlink -f "$BASH_SOURCE" || echo "$BASH_SOURCE"))"

# Parse args
if [[ "$1" == "--new-efi" ]]; then
  CREATE_NEW_EFI="true"
else
  CREATE_NEW_EFI="false"
fi

# Check for intel when using Nvidia Optimus
if which prime-select && [[ "$(prime-select query)" != "intel" ]]; then
  echo "\`prime-select query\` gave \"$(prime-select query)\". It must be \"intel\" for this to work!"
fi

# ================================
# Setup virsh internet Service
# ================================

systemctl start libvirtd.service
systemctl enable libvirtd.service
if ! virsh net-list --all | grep -E 'default(\s+)active'; then
  virsh net-start --network default
fi
virsh net-autostart --network default

# ================================
# Create raid array
# ================================

if [[ "$CREATE_NEW_EFI" == "true" ]]; then
  rm efi1
  dd if=/dev/zero of=efi1 bs=1M count=100
fi
dd if=/dev/zero of=efi2 bs=1M count=1
./create_raid_array

# ================================
# Format the GPT boot record
# ================================

if [[ "$CREATE_NEW_EFI" == "true" ]]; then
  parted --script /dev/md0 -- \
    unit s \
    mktable gpt \
    mkpart primary fat32 2048 204799 \
    mkpart primary ntfs 204800 -2049 \
    set 1 boot on \
    set 1 esp on \
    set 2 msftdata on \
    name 1 EFI \
    name 2 Windows \
    quit
  # Format EFI partition
  mkfs.msdos -F 32 -n EFI /dev/md0p1
else
  # Adjust size of Windows partition if using cached efi1/2
  parted --script /dev/md0 -- \
    unit s \
    resizepart 2 -2049 \
    quit
fi

# ==============================================
# Use bcdboot to install Windows Boot Manager
# into the EFI partition
# ==============================================

if [[ "$CREATE_NEW_EFI" == "true" ]]; then
  echo ""
  echo "STEP 1: Press Enter when it asks if you want to boot to disk"
  echo ""
  echo "STEP 2: Wait until the Windows Installation Medium brings you to the install screen."
  echo "        Then, Press F10 to bring up cmdline"
  echo ""
  echo "STEP 3: Then, in cmdline, run the following: "
  echo ""
  cat <<'EOF'
  diskpart
  DISKPART> list disk
  DISKPART> select disk 0    # Select the disk
  DISKPART> list volume      # Find EFI volume (partition) number
  DISKPART> select volume 2  # Select EFI volume
  DISKPART> assign letter=B  # Assign B: to EFI volume
  DISKPART> exit
  bcdboot C:\Windows /s B: /f ALL
EOF
  echo ""
  echo "When you're done, shutdown the VM"
  echo ""
  ./recovery.sh
fi

# ==============================================
# Give user ability to install virtio drivers
# ==============================================

wget "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.185-2/virtio-win.iso" -O ./virtio-win.iso
echo ""
echo "VM starting..."
echo "When this VM starts, in order to install the internet drivers, please navigate to the virtio mounted CDROM, and double-click virtio-win-gt-x64.msi to install"
echo ""
./start
rm ./virtio-win.iso
