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
  if [[ ! -f ./win10.iso ]]; then
    echo "Error: Cannot find win10.iso in $(pwd)"
    exit 1
  fi
else
  CREATE_NEW_EFI="false"
fi

# Check for missing files
if [[ ! -f ./vbios_gvt_uefi.rom ]]; then
  echo "Error: Cannot find vbios_gvt_uefi.rom in $(pwd)"
  exit 1
fi

# Check for intel when using Nvidia Optimus
if which prime-select && [[ "$(prime-select query)" != "intel" ]]; then
  echo "\`prime-select query\` gave \"$(prime-select query)\". It must be \"intel\" for this to work!"
fi

# ================================
# Create raid array
# ================================

if [[ "$CREATE_NEW_EFI" == "true" ]]; then
  # Reset the GPT and EFI partition when creating a new one
  rm -f efi1
  dd if=/dev/zero of=efi1 bs=1M count=100
elif [[ ! -f ./efi1 ]]; then
  # Verify efi1 exists if we're not making a new efi1
  echo "Error: Cannot find efi1 in $(pwd)"
  exit 1
fi
dd if=/dev/zero of=efi2 bs=1M count=1
./create_raid_array

# ================================
# Format the disk partition table
# ================================

# Format our partition table
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

# Verify the /dev/md0p2 Windows partition integrity inside of the /dev/md0 disk
# This ensures that we set up our GPT table in a way that preserves the windows partition entirely
sleep 0.25 # Give time for /dev/md0p{1,2} to be created
./verify_raid_array

if [[ "$CREATE_NEW_EFI" == "true" ]]; then
  # Format EFI partition
  mkfs.msdos -F 32 -n EFI /dev/md0p1
  # Save UUIDs of disk/partition1/partition2
  DISK_UUID="$(blkid /dev/md0 -s PTUUID -o value)"
  P1_UUID="$(blkid /dev/md0p1 -s PARTUUID -o value)"
  P2_UUID="$(blkid /dev/md0p2 -s PARTUUID -o value)"
  cat >uuid.conf <<EOF
DISK_UUID=$DISK_UUID
P1_UUID=$P1_UUID
P2_UUID=$P2_UUID
EOF
else
  # Source {DISK,P1,P2}_UUID variables
  . uuid.conf
  # Set our disk / partition UUIDs so that the windows boot loader can still identify them
  sgdisk /dev/md0 --disk-guid="$DISK_UUID"
  sgdisk /dev/md0 --partition-guid=1:"$P1_UUID"
  sgdisk /dev/md0 --partition-guid=2:"$P2_UUID"
  # uuid.conf is no longer needed
  rm uuid.conf
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
  # Create .tar.gz to distribute to other users
  GZIP=-9 tar -czvf dual-boot-to-vm.tar.gz ./efi1 ./vbios_gvt_uefi.rom ./uuid.conf
  chown $SUDO_USER:$SUDO_USER ./dual-boot-to-vm.tar.gz
  rm uuid.conf
fi

# ==============================================
# Give user ability to install virtio drivers
# ==============================================

wget "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.185-2/virtio-win.iso" -O ./virtio-win.iso
echo ""
echo "VM starting..."
echo "When this VM starts, in order to install the internet drivers, please navigate to the virtio mounted CDROM, and double-click virtio-win-gt-x64.msi to install"
echo ""
./start --no-igpu
rm ./virtio-win.iso
