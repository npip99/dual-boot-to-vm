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

# Download efi1 and ./vbios_gvt_uefi.rom
curl -L "https://www.dropbox.com/s/gcg735xravwrztl/dual-boot-to-vm.tar.gz?dl=1" | tar -xzv >/dev/null

# ================================
# Update grub file
# ================================

echo "Changing grub file, your grub backup will be stored at $(pwd)/grub_backup.txt"

# Creating a GRUB variable equal to current content of grub cmdline.
GRUB=`cat /etc/default/grub | grep "GRUB_CMDLINE_LINUX_DEFAULT" | rev | cut -c 2- | rev`

# Creating a grub backup for the uninstallation script and making uninstall.sh executable
cat /etc/default/grub > grub_backup.txt
chown $SUDO_USER:$SUDO_USER grub_backup.txt

# After the backup has been created, add intel_iommu=on kvm.ignore_msrs=1 i915.enable_gvt=1
#  to GRUB variable
GRUB+=" intel_iommu=on i915.enable_gvt=1 kvm.ignore_msrs=1\""
sed -i -e "s|^GRUB_CMDLINE_LINUX_DEFAULT.*|${GRUB}|" /etc/default/grub

# User verification of new grub and prompt to manually edit it
echo
echo "Grub was modified to look like this: "
echo `cat /etc/default/grub | grep "GRUB_CMDLINE_LINUX_DEFAULT"`
echo
echo "Do you want to edit it now to fix anything? Y/n (Say yes if there are any duplicated parameters)"
read YN

if [[ $YN = y ]]; then
  "$EDITOR" /etc/default/grub
fi

# Updating grub
update-grub

# ==========================================
# Install dependencies and kernel modules
# ==========================================

# Install required packages for virtualization
pkgs='mdadm ovmf qemu qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager'
if ! dpkg -s $pkgs >/dev/null 2>&1; then
  apt install $pkgs -y
fi

# Adding kernel modules
cat >/etc/modules-load.d/dual-boot-as-vm.conf <<EOF
kvmgt
vfio-iommu-type1
vfio-mdev
EOF

# Updating initramfs
update-initramfs -u

# Now the computer needs to be rebooted so that the new kernel parameters and modules are loaded
while true; do
  echo "Your computer needs to be rebooted"
  echo "To reboot your computer now, please type and enter the letter \"r\""
  read REBOOT

  if [[ $REBOOT = "r" ]]; then
    reboot
  else
    echo "Okay. Your computer needs to be rebooted though. So I'll just wait here"
  fi
done
