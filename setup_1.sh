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

# ==================================
# Install dependencies
# ==================================

# Install required packages
pkgs='mdadm ovmf qemu qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virt-manager'
if ! dpkg -s $pkgs >/dev/null 2>&1; then
  apt install $pkgs -y
fi

# Download efi1 and ./vbios_gvt_uefi.rom
if [[ -e efi1 ]]; then
  echo "File ./efi1 found, cannot continue!"
  exit 1
fi
curl -L "https://www.dropbox.com/s/gcg735xravwrztl/dual-boot-to-vm.tar.gz?dl=1" | tar -xzv >/dev/null

# ==================================
# Created shared pulseaudio socket
# ==================================

PULSEAUDIO_CONFIG="$HOME/.config/pulse/default.pa"
if [[ -f "$PULSEAUDIO_CONFIG" ]]; then
  echo "Custom pulseaudio configuration found at $PULSEAUDIO_CONFIG. Will use that one, but audio might not work"
else
  cat >~/.config/pulse/default.pa <<EOF
.include /etc/pulse/default.pa
load-module module-native-protocol-unix auth-anonymous=1 socket=/tmp/shared-pulse-socket
EOF
  machinectl shell $SUDO_USER@ /bin/systemctl --user restart pulseaudio.service
fi

# ================================
# Update grub file
# ================================

echo "Changing grub file, your grub backup will be stored at $(pwd)/etc_default_grub.bak"

# Creating a GRUB variable equal to current content of grub cmdline.
GRUB=$(cat /etc/default/grub | grep "GRUB_CMDLINE_LINUX_DEFAULT" | rev | cut -c 2- | rev)

# Creating a grub backup for the uninstallation script and making uninstall.sh executable
cat /etc/default/grub > etc_default_grub.bak
chown $SUDO_USER:$SUDO_USER etc_default_grub.bak

# After the backup has been created, add intel_iommu=on kvm.ignore_msrs=1 i915.enable_gvt=1
#  to GRUB variable
GRUB+=" intel_iommu=on i915.enable_gvt=1 i915.enable_fbc=0 kvm.ignore_msrs=1\""
sed -i -e "s|^GRUB_CMDLINE_LINUX_DEFAULT.*|${GRUB}|" /etc/default/grub

# User verification of new grub and prompt to manually edit it
echo
echo "Grub was modified to look like this: "
echo $(cat /etc/default/grub | grep "GRUB_CMDLINE_LINUX_DEFAULT")
echo
echo "Do you want to edit it now to fix anything? Y/n (Say yes if there are any duplicated parameters or the grub config doesn't look right)"
read YN

if [[ "$YN" =~ ^[yY](es)?$ ]]; then
  if [[ -z "$EDITOR" ]]; then
    EDITOR="vim"
  fi
  "$EDITOR" /etc/default/grub
fi

# Updating grub
update-grub

# ==========================================
# Add kernel modules
# ==========================================

# Adding kernel modules
cat >/etc/modules-load.d/dual-boot-as-vm.conf <<EOF
kvmgt
vfio-iommu-type1
vfio-mdev
EOF

# Updating initramfs
update-initramfs -u

# ================================
# Setup virsh internet Service
# ================================

# Allow virbr0 as a network bridge for qemu
mkdir -p /etc/qemu
if [[ -f /etc/qemu/bridge.conf ]]; then
  echo "/etc/qemu/bridge.conf found. Overwriting it, but a backup can be found at $(pwd)/etc_qemu_bridge.conf.bak"
  cp /etc/qemu/bridge.conf ./etc_qemu_bridge.conf.bak
fi
echo "allow virbr0" >/etc/qemu/bridge.conf
# Get virbr0 networking device working
# Can comment out --start since we'll reboot anyway
# systemctl start libvirtd.service
systemctl enable libvirtd.service
# if ! virsh net-list --all | grep -E 'default(\s+)active'; then
#   virsh net-start --network default
# fi
virsh net-autostart --network default

# Now the computer needs to be rebooted so that the new kernel parameters and modules are loaded
while true; do
  echo "Your computer needs to be rebooted"
  echo "To reboot your computer now, please type and enter the letter \"r\""
  read REBOOT

  if [[ "$REBOOT" == "r" ]]; then
    reboot
  else
    echo "Okay. Your computer needs to be rebooted though. So I'll just wait here"
  fi
done
