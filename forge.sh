#!/bin/bash
set -eo pipefail

APTCACHER=""
ARCH="amd64"
BINFMT=""
BOOTOPTIONS=""
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
IMAGEFORMAT="qcow2"
IMAGESIZE="10G"
INSTALLDEPS=""
LABEL=""
LUKS=""
MOUNT=""
OUTPUTPATH="./debian"
OUTPUTTYPE="filesystem"
PACKAGES=""
PARTITION=""
PROFILE=""
ROOTPASSWORD=""
ROOTKEY="./id_rsa.pub"
SQUASH=""
SWAPSIZE=""
TEMPDIR="$(pwd)/tmp"
VERSION="bullseye"

diskpath=""
exclude=""

function show_usage() {
  echo "Usage: $0 [arguments] [disk|filesystem|image]

Arguments:
  -ac [apt-cacher-address]  apt-cacher-ng proxy
  -ap [packages]            additional packages to include
  -ar [architecture]        architecture (amd64, arm64) (default: ${ARCH})
  -bo                       boot options
  -d                        enable debugging
  -h                        show help
  -if                       image format (qcow2, raw) (default: ${IMAGEFORMAT})
  -is [size]                image size (default: ${IMAGESIZE})
  -la [label]               append a custom label to partition names
  -lu                       enable LUKS for image
  -m                        just mount the disk/image
  -o [path]                 output directory (filesystem), target disk (disk) or filename without extension (image) (default: ${OUTPUTPATH})
  -pp                       if hardware device requires a partition prefix, like nvme0n1 partition 1 = nvme0n1p1
  -pr [profile]             use a specific hardware profile (odroidn2, pinebookpro) (default: none)
  -rk [password]            filename for root SSH public key (default: ${ROOTKEY})
  -rp [password]            root password (default: none)
  -sq                       have output be squashfs
  -sw [size]                swap size (default: none/no swap)
  -t [path]                 temporary files directory (default: ${TEMPDIR})
  -v [version]              debian version to install (default: buster)"
  exit 0
}

function provision() {
  if [ ${OUTPUTTYPE} == image ]; then
    if [ ! -e "${OUTPUTPATH}" ]; then
      qemu-img create -f "${IMAGEFORMAT}" "${OUTPUTPATH}" "${IMAGESIZE}"
      modprobe nbd max_part=4
      qemu-nbd -c /dev/nbd0 -f "${IMAGEFORMAT}" "${OUTPUTPATH}"

      sleep 1
    else
      return 0
    fi
  fi

  if [ "${diskpath}" ]; then
    if [ ! -e "/dev/disk/by-label/efi${LABEL}" ]; then
      parted "${diskpath}" mklabel gpt

      case "${PROFILE}" in
        odroidn2)
        ;;
        pinebookpro)
          dd if=/usr/lib/u-boot/pinebook-pro-rk3399/idbloader.img conv=notrunc seek=64 "of=${diskpath}"
          dd if=/usr/lib/u-boot/pinebook-pro-rk3399/u-boot.itb conv=notrunc seek=16384 "of=${diskpath}"
          parted "${diskpath}" mkpart primary 32768s 442367s
          parted "${diskpath}" set 1 esp on
          sleep 1
          mkfs.vfat -n "efi${LABEL}" "${diskpath}${PARTITION}1"
          parted "${diskpath}" mkpart primary 442368s 100%
        ;;
        *)
          parted "${diskpath}" mkpart primary fat32 1MiB 200MiB
          parted "${diskpath}" set 1 esp on
          sleep 1
          mkfs.vfat -n "efi${LABEL}" "${diskpath}${PARTITION}1"
          parted "${diskpath}" mkpart primary 200MiB 100%
        ;;
      esac

      if [ "${LUKS}" ]; then
        cryptsetup --label "luks${LABEL}" -v luksFormat --type luks2 "${diskpath}${PARTITION}2"
        cryptsetup open "/dev/disk/by-label/luks${LABEL}" "luks${LABEL}"
        mkfs.btrfs -L "btrfs${LABEL}" "/dev/mapper/luks${LABEL}"
      else
        mkfs.btrfs -L "btrfs${LABEL}" "/dev/mapper/luks${LABEL}"
      fi

      sleep 1
      mkdir -p "${TEMPDIR}"
      mount "/dev/disk/by-label/btrfs${LABEL}" "${TEMPDIR}"

      btrfs sub create "${TEMPDIR}/debian-${VERSION}"

      if [ "${SWAPSIZE}" ]; then
        btrfs sub create "${TEMPDIR}/@swap"
        truncate -s 0 "${TEMPDIR}/@swap/swapfile"
        chattr +C "${TEMPDIR}/@swap/swapfile"
        btrfs property set "${TEMPDIR}/@swap/swapfile" compression none
        fallocate -l "${SWAPSIZE}" "${TEMPDIR}/@swap/swapfile"
        chmod 0600 "${TEMPDIR}/@swap/swapfile"
        mkswap "${TEMPDIR}/@swap/swapfile"
      fi

      umount "/dev/disk/by-label/btrfs${LABEL}"
    fi
  fi
}

function mountfs() {
  mkdir -p "${TEMPDIR}"

  if [ "${diskpath}" ] && ! mount | grep "${TEMPDIR}"; then
    if [ "${OUTPUTTYPE}" == image ] && [ ! -e "/dev/disk/by-label/efi${LABEL}" ]; then
      modprobe nbd max_part=4
      qemu-nbd -c /dev/nbd0 -f "${IMAGEFORMAT}" "${OUTPUTPATH}"

      sleep 1
    fi

    if [ "${LUKS}" ] && [ ! -e "/dev/mapper/luks${LABEL}" ]; then
      cryptsetup open "/dev/disk/by-label/luks${LABEL}" "luks${LABEL}"
    fi

    mount "/dev/disk/by-label/btrfs${LABEL}" -o "subvol=debian-${VERSION}" "${TEMPDIR}"

    if [ "${diskpath}" ]; then
      mkdir -p "${TEMPDIR}/boot/efi"
      mount "/dev/disk/by-label/efi${LABEL}" "${TEMPDIR}/boot/efi" || true
    fi
  fi
}

function install() {
  if [ "${diskpath}" ]; then
    BOOTOPTIONS="root=LABEL=btrfs${LABEL} rootflags=subvol=debian-${VERSION},${BOOTOPTIONS}"
    PACKAGES="btrfs-progs,linux-image-${ARCH},${PACKAGES}"
  fi

  if [ "${LUKS}" ]; then
    PACKAGES="cryptsetup,cryptsetup-initramfs,${PACKAGES}"
  fi

  if [ "${diskpath}" ]; then
    PACKAGES="lvm2,${PACKAGES}"
  fi

  if [ "${FEATSQUASH}" ]; then
    PACKAGES="cryptsetup,debootstrap,dosfstools,firmware-linux,firmware-iwlwifi,linux-image-${ARCH},live-boot,lvm2,parted,${PACKAGES}"
  fi

  if [ ! -e "${TEMPDIR}/bin" ]; then
    deboptions=""
    if ! uname -a | grep "${ARCH}"; then
      deboptions="--foreign"
    fi

    debootstrap ${deboptions} --arch "${ARCH}" --components=main,contrib,non-free --include "apt-transport-https,ca-certificates,curl,gnupg2,jq,libpam-systemd,locales,openssh-server,policykit-1,python3-minimal,${PACKAGES}" --exclude "cron,ifupdown,logrotate,nano,rsyslog,${exclude}" "${VERSION}" "${TEMPDIR}" "http://${APTCACHER}deb.debian.org/debian"

    if ! uname -a | grep "${ARCH}"; then
      cp "/usr/bin/qemu-${BINFMT}-static" "${TEMPDIR}/usr/bin"
      chroot "${TEMPDIR}" /debootstrap/debootstrap --second-stage
    fi
  fi
}

function configure() {
  # Edit sources
  cat > "${TEMPDIR}/etc/apt/sources.list" << EOF
deb http://${APTCACHER}deb.debian.org/debian ${VERSION} main contrib non-free
deb http://${APTCACHER}deb.debian.org/debian ${VERSION}-updates main contrib non-free
deb http://${APTCACHER}security.debian.org/debian-security ${VERSION}-security main contrib non-free
EOF

  # Dynamic hostname
  rm -f "${TEMPDIR}/etc/hostname" || true

  # Prevent packages from starting services
  cat > "${TEMPDIR}/usr/sbin/policy-rc.d" << EOF
exit 101
EOF

  # Default systemd networking
  cat > "${TEMPDIR}/etc/systemd/network/default.network" << EOF
[Match]
Name=!lo

[Network]
DHCP=yes
EOF

  # Enable services
  for service in polkit systemd-networkd systemd-networkd-wait-online systemd-resolved systemd-timesyncd; do
    ln -s "/lib/systemd/system/${service}.service" "${TEMPDIR}/etc/systemd/system/multi-user.target.wants" || true
  done

  # Remove timers
  rm "${TEMPDIR}/etc/systemd/system/timers.target.wants/"* || true

  # Setup resolved
  ln -sf /run/systemd/resolve/resolv.conf "${TEMPDIR}/etc/resolv.conf"
  mkdir -p "${TEMPDIR}/etc/systemd/resolved.conf.d"
  cat > "${TEMPDIR}/etc/systemd/resolved.conf.d/override.conf" << EOF
[Resolve]
FallbackDNS=1.1.1.1
EOF

  # Set root SSH key
  mkdir -p "${TEMPDIR}/root/.ssh"
  cp "${ROOTKEY}" "${TEMPDIR}/root/.ssh/authorized_keys"

  # Set root password
  if [ "${ROOTPASSWORD}" ]; then
    chroot "${TEMPDIR}" bash -c "echo \"root:${ROOTPASSWORD}\" | chpasswd"
  fi
}

function finalize() {
  chroot "${TEMPDIR}" apt clean

  if [ "${diskpath}" ]; then
    cat > "${TEMPDIR}/etc/fstab" << EOF
LABEL=efi${LABEL} /boot/efi vfat defaults 0 1
EOF

    # Setup EFI copy
    cat > "${TEMPDIR}/usr/local/sbin/generate_loaders.sh" << EOS
#!/usr/bin/env bash

rm -rf /boot/efi/loader/entries/*
for kernel in /boot/vmlinuz-*; do
  version=\${kernel#*-}
  cp -f "/boot/initrd.img-\${version}" /boot/efi/
  cp -f "/boot/vmlinuz-\${version}" /boot/efi/
  cat > /boot/efi/loader/entries/debian10-\${version}.conf << EOF
title Debian ${VERSION} - \${version}
linux /vmlinuz-\${version}
initrd /initrd.img-\${version}
options ${BOOTOPTIONS} rw
EOF
done
EOS
    chmod +x "${TEMPDIR}/usr/local/sbin/generate_loaders.sh"

    cat > "${TEMPDIR}/etc/systemd/system/efi.service" << EOF
[Unit]
Description=Copy initramfs and vmlinuz to EFI System Partitions

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/generate_loaders.sh
EOF

    cat > "${TEMPDIR}/etc/systemd/system/efi.path" << EOF
[Unit]
Description=Copy initramfs and vmlinuz to EFI System Partitions

[Path]
PathChanged=/initrd.img
PathChanged=/vmlinuz

[Install]
WantedBy=multi-user.target
EOF

    ln -sf /etc/systemd/system/efi.path "${TEMPDIR}/etc/systemd/system/multi-user.target.wants/" || true

    # Setup systemd-bootd
    if [ ! -e "${TEMPDIR}/boot/efi/loader" ]; then
      mount -o bind /dev "${TEMPDIR}/dev"
      mount -t sysfs /sys "${TEMPDIR}/sys"
      mount -t proc /proc "${TEMPDIR}/proc"
      chroot "${TEMPDIR}" bootctl --esp-path /boot/efi install || true
      umount "${TEMPDIR}/dev"
      umount "${TEMPDIR}/sys"
      umount "${TEMPDIR}/proc"
    fi

    cat > "${TEMPDIR}/boot/efi/loader/loader.conf" << EOF
default debian${VERSION}-*
timeout 3
EOF

    if [ "${LUKS}" ]; then
      cat >> "${TEMPDIR}/etc/crypttab" << EOF
luks LABEL=luks${LABEL} none luks,initramfs
EOF
      mount -o bind /dev "${TEMPDIR}/dev"
      mount -t sysfs /sys "${TEMPDIR}/sys"
      mount -t proc /proc "${TEMPDIR}/proc"
      chroot "${TEMPDIR}" update-initramfs -u
      umount "${TEMPDIR}/dev"
      umount "${TEMPDIR}/sys"
      umount "${TEMPDIR}/proc"
    fi

    chroot "${TEMPDIR}" /usr/local/sbin/generate_loaders.sh
  fi

  if [ "${diskpath}" ]; then
    cat >> "${TEMPDIR}/etc/fstab" << EOF
LABEL=btrfs${LABEL} / btrfs defaults 0 0
EOF

    if [ "${SWAPSIZE}" ]; then
      cat >> "${TEMPDIR}/etc/fstab" << EOF
LABEL=btrfs${LABEL} /swap btrfs defaults,subvol=@swap 0 0
/swap/swapfile none swap defaults 0 0
EOF
    fi
  fi

  if [ "${SQUASH}" ]; then
    mkdir -p "${TEMPDIR}/etc/systemd/system/getty@tty1.service.d"
    cat > "${TEMPDIR}/etc/systemd/system/getty@tty1.service.d/override.conf" << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 38400 linux
EOF
    mkdir -p "${TEMPDIR}/etc/systemd/system/serial-getty@ttyS0.service.d"
    # Include additional squash modules
    cat > "${TEMPDIR}/etc/initramfs-tools/modules" << EOF
asix
iwlwifi
usbnet
EOF
    mount -o bind /dev "${TEMPDIR}/dev"
    mount -t sysfs /sys "${TEMPDIR}/sys"
    mount -t proc /proc "${TEMPDIR}/proc"
    chroot "${TEMPDIR}" update-initramfs -u
    umount "${TEMPDIR}/dev"
    umount "${TEMPDIR}/sys"
    umount "${TEMPDIR}/proc"
    cp -R "${TEMPDIR}/etc/systemd/system/serial-getty@ttyS0.service.d" "${TEMPDIR}/etc/systemd/system/getty@tty1.service.d"
    cp -R "${DIR}/forge.sh" "${TEMPDIR}/usr/local/bin/forge.sh"
    mkdir -p "${OUTPUTPATH}"
    cp "${TEMPDIR}/vmlinuz" "${OUTPUTPATH}/vmlinuz"
    cp "${TEMPDIR}/initrd.img" "${OUTPUTPATH}/initrd.img"
    mksquashfs "${TEMPDIR}" "${OUTPUTPATH}/root.squashfs" -e boot
    cp -R /boot/efi/EFI "${OUTPUTPATH}/EFI"
    mkdir -p "${OUTPUTPATH}/loader/entries"
    cat >> "${OUTPUTPATH}/loader/loader.conf" << EOF
default Debian
EOF
    cat >> "${OUTPUTPATH}/loader/entries/debian.conf" << EOF
title Debian
linux /vmlinuz
initrd /initrd.img
options boot=live fromiso=/root.squashfs toram
EOF
  fi

  if [ "${diskpath}" ]; then
    umount -R "${TEMPDIR}" || true

    if [ "${LUKS}" ]; then
      cryptsetup close "/dev/mapper/luks${LABEL}" || true
    fi

    qemu-nbd -d /dev/nbd0 || true
    rmdir "${TEMPDIR}"
  fi

  if [ ! "${diskpath}" ]; then
    mv "${TEMPDIR}" "${OUTPUTPATH}"
  fi
}

if [ -z "${1}" ]; then
  show_usage
fi

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

while [ $# -gt 0 ]; do
  case "${1}" in
    -ac)
      APTCACHER="${2}/"
      shift 2
    ;;
    -ap)
      PACKAGES="${2}"
      shift 2
    ;;
    -ar)
      case "${2}" in
        amd64)
          ARCH=amd64
        ;;
        arm64)
          ARCH=arm64
          BINFMT=aarch64
        ;;
      esac
      shift 2
    ;;
    -bo)
      BOOTOPTIONS="${2}"
      shift 2
    ;;
    -d)
      set -x
      shift 1
    ;;
    -h)
      show_usage
    ;;
    -if)
      case "${2}" in
        qcow2)
          IMAGEFORMAT=qcow2
        ;;
        raw)
          IMAGEFORMAT=raw
        ;;
      esac
      shift 2
    ;;
    -is)
      IMAGESIZE="${2}"
      shift 2
    ;;
    -la)
      LABEL="-${2}"
      shift 2
    ;;
    -lu)
      LUKS=yes
      shift 1
    ;;
    -m)
      MOUNT=yes
      shift 1
    ;;
    -o)
      OUTPUTPATH="${2}"
      shift 2
    ;;
    -p)
      PROFILE="${2}"
      shift 2
    ;;
    -pp)
      PARTITION="p"
      shift 2
    ;;
    -rk)
      ROOTKEY="${2}"
      shift 2
    ;;
    -rp)
      ROOTPASSWORD="${2}"
      shift 2
    ;;
    -sq)
      SQUASH=yes
      shift 1
    ;;
    -sw)
      SWAPSIZE="${2}"
      shift 2
    ;;
    -t)
      TEMPDIR="${2}"
      shift 2
    ;;
    -v)
      VERSION="${2}"
      shift 2
    ;;
    disk)
      diskpath="${OUTPUTPATH}"
      OUTPUTTYPE=disk
      shift 1
    ;;
    filesystem)
      OUTPUTTYPE=filesystem
      shift 1
    ;;
    image)
      diskpath="/dev/nbd0"
      PARTITION="p"
      OUTPUTTYPE=image
      shift 1
    ;;
    *)
      show_usage
  esac
done

if ! [ -x "$(command -v debootstrap)" ]; then
  INSTALLDEPS+=" debootstrap"
fi

if ! uname -a | grep "${ARCH}" && ! [ -x "$(command -v /usr/bin/qemu-${BINFMT}-static)" ] ; then
  INSTALLDEPS+=" binfmt-support qemu-user-static"
fi

if [ "${EFI}" ] && ! [ -x "$(command -v parted)" ]; then
  INSTALLDEPS+=" parted"
fi

if [ "${diskpath}" == /dev/nbd0 ] && ! [ -x "$(command -v qemu-nbd)" ]; then
  INSTALLDEPS+=" qemu-utils"
fi

if [ "${SQUASH}" ] && ! [ -x "$(command -v mksquashfs)" ]; then
  INSTALLDEPS+=" squashfs-tools"
fi

case "${PROFILE}" in
  odroidn2)
    INSTALLDEPS+="u-boot-amlogic"
  ;;
  pinebookpro)
    INSTALLDEPS+="u-boot-rockchip"
  ;;
esac

if [ "${INSTALLDEPS}" ]; then
  apt update && apt install -y ${INSTALLDEPS}
fi

if [ "${MOUNT}" ]; then
  mountfs
  exit
fi

provision
mountfs
install
configure
finalize
