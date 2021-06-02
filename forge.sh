#!/bin/bash
set -eo pipefail

ADDITIONAL=""
APTCACHER=""
ARCH="amd64"
BINFMT=""
BOOTLOADER=""
BOOTOPTIONS="elevator=noop root=LABEL=root${LABLE}"
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
IMAGEFORMAT="qcow2"
IMAGESIZE="10G"
IMAGESWAP=""
INSTALLDEPS=""
LABEL=""
LUKS=""
OUTPUTPATH="./debian"
OUTPUTTYPE="filesystem"
PASSWORD=""
SQUASH=""
TEMPDIR="$(pwd)/tmp"
UBOOTIDB=""
UBOOTITP=""
UBOOTVERSION="rockchip"
USERHOME="/home/ansible"
USERKEY="./id_rsa.pub"
USERNAME="ansible"
VERSION="bullseye"

diskpath=""
exclude=""
partition=""

function show_usage() {
  echo "Usage: $0 [arguments] [disk|filesystem|image|mount]

Arguments:
  -ac [apt-cacher-address]  apt-cacher-ng proxy
  -ap [packages]            additional packages to include after install
  -ar [architecture]        architecture (amd64, arm64) (default: ${ARCH})
  -bl                       bootloader (bios, uboot, uefi) (default: none/no bootloader or kernel)
  -bo                       boot options
  -d                        enable debugging
  -if                       image format (qcow2, raw) (default: ${IMAGEFORMAT})
  -is [size]                image size (default: ${IMAGESIZE})
  -iw [size]                image swap size (default: none/no swap)
  -h                        show help
  -la                       append a custom label to partition names
  -lu                       enable LUKS for image
  -o [path]                 output directory (filesystem), target disk (disk) or filename without extension (image) (default: ${OUTPUTPATH})
  -p [password]             root password (default: none)
  -s                        have output be squashfs
  -t [path]                 temporary files directory (default: ${TEMPDIR})
  -uh [path]                home dir for initial user (default: ${USERHOME})
  -ui [path]                u-boot IDB path (idbloader.img) (default: none/no idb)
  -uk [filename]            filename for SSH public key to add to initial user (default: ${USERKEY})
  -un [username]            username for initial user (default: ${USERNAME})
  -uo [path]                u-boot ITB path (u-boot.itb) (default: none/no itp)
  -uv [version]             u-boot version to install (default: ${UBOOTVERSION})
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
    if [ ! -e "/dev/lvm${LABEL}/root${LABEL}" ]; then
      case "${BOOTLOADER}" in
        bios)
          parted "${diskpath}" mklabel msdos
          parted "${diskpath}" mkpart primary 1MiB 200MiB
          parted "${diskpath}" set 1 boot on
	  sleep 1
          mkfs.ext4 -L "boot${LABEL}" "${diskpath}${partition}1"
          parted "${diskpath}" mkpart primary 200MiB 100%
        ;;
        uboot)
          parted "${diskpath}" mklabel gpt
          dd "if=${UBOOTIDB}" conv=notrunc seek=64 "of=${diskpath}"
          dd "if=${UBOOTITP}" conv=notrunc seek=16384 "of=${diskpath}"
          parted "${diskpath}" mkpart primary 24576s 200MiB
	  sleep 1
          mkfs.vfat -n "boot${LABEL}" "${diskpath}${partition}1"
          parted "${diskpath}" mkpart primary 200MiB 100%
	  BOOTLOADER=uefi
        ;;
        uefi)
          parted "${diskpath}" mkpart primary fat32 1MiB 200MiB
          parted "${diskpath}" set 1 esp on
	  sleep 1
          mkfs.vfat -n "efi${LABEL}" "${diskpath}${partition}1"
          parted "${diskpath}" mkpart primary 200MiB 100%
        ;;
      esac

      if [ "${LUKS}" ]; then
        cryptsetup --label "luks${LABEL}" -v luksFormat --type luks2 "${diskpath}${partition}2"
        cryptsetup open "/dev/disk/by-label/luks${LABEL}" "luks${LABEL}"
        vgcreate "lvm${LABEL}" "/dev/mapper/luks${LABEL}"
      else
        vgcreate "lvm${LABEL}" "${diskpath}${partition}2" || true
      fi

      if [ "${IMAGESWAP}" ]; then
        lvcreate -n "swap${LABEL}" -L "${IMAGESWAP}" "lvm${LABEL}"
        mkswap -L "swap${LABEL}" "/dev/lvm${LABEL}/swap${LABEL}"
      fi

      lvcreate -n "root${LABEL}" -l "100%FREE" "lvm${LABEL}"
      mkfs.ext4 -L "root${LABEL}" "/dev/lvm${LABEL}/root${LABEL}"
    fi
  fi

  if [ "${FEATIMAGE}" ]; then
    mkfs.ext4 -L "root" "${FEATIMAGEROOT}"
    qemu-nbd -d /dev/nbd0

    qemu-nbd -c /dev/nbd0 -f "${FEATIMAGEFORMAT}" "${IMAGENAME}"
    sleep 1

  fi
}

function mountfs() {
  mkdir -p "${TEMPDIR}"

  if [ "${diskpath}" ] && ! mount | grep "${TEMPDIR}"; then
    if [ "${OUTPUTTYPE}" == image ] && ! parted /dev/nbd0 print; then
      modprobe nbd max_part=4
      qemu-nbd -c /dev/nbd0 -f "${IMAGEFORMAT}" "${OUTPUTPATH}"

      sleep 1
    fi

    if [ "${LUKS}" ]; then
      cryptsetup open "/dev/disk/by-label/luks${LABEL}" "luks${LABEL}"
    fi

    mount "/dev/disk/by-label/root${LABEL}" "${TEMPDIR}" || true

    if [ "${BOOTLOADER}" == uefi ]; then
      mkdir -p "${TEMPDIR}/boot/efi"
      mount "/dev/disk/by-label/efi${LABEL}" "${TEMPDIR}/boot/efi" || true
    elif [ "${BOOTLOADER}" == bios ] || [ "${BOOTLOADER}" == uboot ]; then
      mount "/dev/disk/by-label/boot${LABEL}" "${TEMPDIR}/boot" || true
    fi
  fi
}

function install() {
  PACKAGES=""

  if [ "${BOOTLOADER}" ]; then
    PACKAGES="linux-image-${ARCH},${PACKAGES}"
  fi

  if [ "${BOOTLOADER}" == bios ]; then
    PACKAGES="grub2,parted,${PACKAGES}"
  fi

  if [ "${BOOTLOADER}" == uboot ]; then
    PACKAGES="u-boot-${UBOOTVERSION},${PACKAGES}"
  fi

  if [ "${LUKS}" ]; then
    BOOTOPTIONS="resume=LABEL=swap${LABEL} root=LABEL=root${LABEL},${BOOTOPTIONS}"
    PACKAGES="cryptsetup,cryptsetup-initramfs,${PACKAGES}"
  fi

  if [ "${diskpath}" ]; then
    PACKAGES="lvm2,${PACKAGES}"
  fi

  if [ "${FEATSQUASH}" ]; then
    PACKAGES="cryptsetup,debootstrap,dosfstools,firmware-linux,firmware-iwlwifi,linux-image-${ARCH},live-boot,lvm2,parted,${PACKAGES}"
  fi

  echo ${PACKAGES}

  if [ ! -e "${TEMPDIR}/bin" ]; then
    deboptions=""
    if ! uname -a | grep "${ARCH}"; then
      deboptions="--foreign"
    fi

    debootstrap "${deboptions}" --arch "${ARCH}" --components=main,contrib,non-free --include "apt-transport-https,ca-certificates,curl,dbus,gnupg2,jq,libpam-systemd,locales,openssh-server,policykit-1,python3-minimal,sudo,usrmerge,unzip,${PACKAGES}" --exclude "cron,ifupdown,iptables,logrotate,nano,rsyslog,${exclude}" "${VERSION}" "${TEMPDIR}" "http://${APTCACHER}deb.debian.org/debian"

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
EOF
  if [ ${VERSION} = "bullseye" ]; then
    cat >> "${TEMPDIR}/etc/apt/sources.list" << EOF
deb http://${APTCACHER}deb.debian.org/debian ${VERSION}-updates main contrib non-free
deb http://${APTCACHER}security.debian.org/debian-security ${VERSION}-security main contrib non-free
EOF
  fi

  # Dynamic hostname
  rm -f "${TEMPDIR}/etc/hostname" || true

  cat > "${TEMPDIR}/usr/sbin/policy-rc.d" << EOF
exit 101
EOF

  # Install additional packages
  if [ "${ADDITIONAL}" ]; then
    if ! grep -qs "${TEMPDIR}/dev" /proc/mounts; then
      mount -o bind /dev "${TEMPDIR}/dev"
    fi
    if ! grep -qs "${TEMPDIR}/sys" /proc/mounts; then
      mount -o bind /sys "${TEMPDIR}/sys"
    fi
    if ! grep -qs "${TEMPDIR}/proc" /proc/mounts; then
      mount -o bind /proc "${TEMPDIR}/proc"
    fi
    cp /etc/resolve.conf "${TEMPDIR}/etc/resolv.conf"
    chroot "${TEMPDIR}" /bin/bash -c "apt update && apt install -y ${ADDITIONAL}"
    rm "${TEMPDIR}/etc/resolv.conf"
    umount "${TEMPDIR}/dev"
    umount "${TEMPDIR}/sys"
    umount "${TEMPDIR}/proc"
  fi

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

  # Create user
  chroot "${TEMPDIR}" useradd -c "${USERNAME}" -d "${USERHOME}" -mu 2000 "${USERNAME}" || true
  cat > "${TEMPDIR}/etc/sudoers" << EOF
Defaults env_reset
Defaults mail_badpass
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

root ALL=(ALL:ALL) ALL

%admin ALL=(ALL) NOPASSWD: ALL
EOF
  chroot "${TEMPDIR}" groupadd admin || true
  chroot "${TEMPDIR}" gpasswd -a "${USERNAME}" admin || true
  chroot "${TEMPDIR}" mkdir -p "${USERHOME}"/.ssh
  chroot "${TEMPDIR}" mkdir -p "${USERHOME}"/.ssh
  chroot "${TEMPDIR}" touch "${USERHOME}"/.ssh/authorized_keys
  chroot "${TEMPDIR}" chown "${USERNAME}:${USERNAME}" "${USERHOME}/.ssh"
  cp "${USERKEY}" "${TEMPDIR}${USERHOME}"/.ssh/authorized_keys

  # Set root password
  if [ "${PASSWORD}" ]; then
    echo "root:${PASSWORD}" | chpasswd -R "${TEMPDIR}"
  fi
}

function finalize() {
  chroot "${TEMPDIR}" apt clean

  if [ "${BOOTLOADER}" == uefi ]; then
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
title Debian 10 - \${version}
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
      bootctl --path "${TEMPDIR}/boot/efi" install
    fi

    cat > "${TEMPDIR}/boot/efi/loader/loader.conf" << EOF
default debian10-*
timeout 3
EOF

    cat > "${TEMPDIR}/boot/efi/loader/entries/debian.conf" << EOF
title Debian 10 -
linux /vmlinuz
initrd /initrd.img
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
LABEL=root${LABEL} / ext4 defaults,noatime 0 1
EOF

    if [ "${IMAGESWAP}" ]; then
      cat >> "${TEMPDIR}/etc/fstab" << EOF
LABEL=swap${LABEL} none swap defaults 0 0
EOF
    fi

    if [ "${BOOTLOADER}" == bios ] || [ "${BOOTLOADER}" == uboot ]; then
      cat >> "${TEMPDIR}/etc/fstab" << EOF
LABEL=boot${LABEL} /boot ext4 defaults,noatime 0 1
EOF
      mount -o bind /dev "${TEMPDIR}/dev"
      mount -t proc /proc "${TEMPDIR}/proc"
      mount -t sysfs /sys "${TEMPDIR}/sys"

      if [ "${BOOTLOADER}" == bios ]; then
        sed -i 's/#GRUB_TERMINAL/GRUB_TERMINAL/g' "${TEMPDIR}/etc/default/grub"
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/g' "${TEMPDIR}/etc/default/grub"
        chroot "${TEMPDIR}" grub-install "${diskpath}"
	chroot "${TEMPDIR}" grub-mkconfig -o /boot/grub/grub.cfg
      fi

      sleep 1
      umount "${TEMPDIR}/dev"
      umount "${TEMPDIR}/proc"
      umount "${TEMPDIR}/sys"
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
    vgchange -an "/dev/lvm${LABEL}" || true
    qemu-nbd -d /dev/nbd0 || true
    rmdir "${TEMPDIR}"

    if [ "${LUKS}" ]; then
      cryptsetup close "/dev/mapper/luks${LABEL}" || true
    fi
  fi

  if [ ! "${BOOTLOADER}" ]; then
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
      ADDITIONAL="${2}"
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
    -bl)
      case "${2}" in
        bios)
          BOOTLOADER=bios
        ;;
        uboot)
          BOOTLOADER=uboot
        ;;
        uefi)
          BOOTLOADER=uefi
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
    -iw)
      IMAGESWAP="${2}"
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
    -o)
      OUTPUTPATH="${2}"
      shift 2
    ;;
    -p)
      PASSWORD="${2}"
      shift 2
    ;;
    -s)
      BOOTLOADER=squash
      SQUASH="${2}"
      shift 1
    ;;
    -t)
      TEMPDIR="${2}"
      shift 2
    ;;
    -uh)
      USERHOME="${2}"
      shift 2
    ;;
    -ui)
      UBOOTIDB="${2}"
      shift 2
    ;;
    -uk)
      USERKEY="${2}"
      shift 2
    ;;
    -un)
      USERNAME="${2}"
      shift 2
    ;;
    -uo)
      UBOOTITP="${2}"
      shift 2
    ;;
    -uv)
      UBOOTVERSION="${2}"
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
      partition="p"
      OUTPUTTYPE=image
      shift 1
    ;;
    mount)
      diskpath="${OUTPUTPATH}"
      mountfs
      exit
    ;;
    *)
      show_usage
  esac
done

if ! [ -x "$(command -v debootstrap)" ]; then
  INSTALLDEPS+=" debootstrap"
fi

if [ "${OUTPUTTYPE}" == image ] || [ "${OUTPUTTYPE}" == disk ] && ! [ -x "$(command -v vgcreate)" ]; then
  INSTALLDEPS+=" lvm2"
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

if [ "${INSTALLDEPS}" ]; then
  apt update && apt install -y ${INSTALLDEPS}
fi

provision
mountfs
install
configure
finalize
