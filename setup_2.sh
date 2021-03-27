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

# Check for intel when using Nvidia Optimus
if which prime-select && [[ "$(prime-select query)" != "intel" ]]; then
  echo "\`prime-select query\` gave \"$(prime-select query)\". It must be \"intel\" for this to work!"
fi

# ================================
# Setup Intel vGPU Service
# ================================

GPU=
MAX=0
UUID=$(uuidgen)

# Finding the Intel GPU and choosing the one with highest weight value
for i in $(find /sys/devices/pci* -name 'mdev_supported_types'); do
  for y in $(find $i -name 'description'); do
    WEIGHT=$(cat $y | tail -1 | cut -d ' ' -f 2)
    if [ $WEIGHT -gt $MAX ]; then
      GPU=$(echo $y | cut -d '/' -f 1-7)
    fi
  done
done

if [[ -z "$GPU" ]]; then
  echo "Error: No Intel GPU found"
  exit 1
fi

# Saving the UUID for future usage
echo "#!/bin/bash" >check_gpu.sh
echo "ls $GPU/devices | grep -o $UUID" >>check_gpu.sh
chmod +x check_gpu.sh
chown $SUDO_USER check_gpu.sh

if [[ "$1" == "--new-efi" ]]; then
  CREATE_NEW_EFI="true"
else
  CREATE_NEW_EFI="false"
fi

# Setup virt pci to be automatic
systemctl start libvirtd.service
systemctl enable libvirtd.service

# ================================
# Setup virsh internet Service
# ================================

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
  qemu-system-x86_64 \
    -bios /usr/share/ovmf/OVMF.fd \
    -drive file=/dev/md0,media=disk,format=raw \
    -cpu host -smp 6,sockets=1,cores=3,threads=2 -enable-kvm \
    -m 8G \
    -cdrom ./win10.iso -msg timestamp=on
fi

# ==============================================
# Give user ability to install virtio drivers
# ==============================================

wget "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.185-2/virtio-win.iso" -O ./virtio-win.iso
echo ""
echo "VM starting..."
echo "When this VM starts, in order to activate the internet, please navigate to the virtio mounted CDROM, and double-click virtio-win-gt-x64.msi to install"
echo ""
./start
rm ./virtio-win.iso
