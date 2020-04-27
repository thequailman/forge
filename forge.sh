#!/bin/bash
set -eo pipefail

ADDITIONAL=""
ARCH="amd64"
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
EXCLUDE=""
FEATCONTAINER=""
FEATDIRECT=""
FEATEFI=""
FEATFORMAT=""
FEATLINUXAMD64=""
FEATIMAGE=""
FEATIMAGEFORMAT="qcow2"
FEATIMAGESIZE="10G"
FEATIMAGEROOT="/dev/nbd0p1"
FEATLUKS=""
FEATSQUASH=""
INITUSERHOME="/home/ansible"
INITUSERKEY="./id_rsa.pub"
INITUSERNAME="ansible"
INSTALLDEPS=""
NAMESERVER="1.1.1.1"
OPTIONS="elevator=noop root=LABEL=root"
OUTPUT="./debian"
PASSWORD=""
PROXY=""
TEMPDIR="$(pwd)/tmp"
VERSION="buster"

function show_usage() {
  echo "Usage: $0 [arguments]

Arguments:
  -a [apt-cacher-address]   apt-cacher-ng proxy
  -b                        boot options
  -d                        enable debugging
  -f                        image format (default: qcow2)
  -h                        show help
  -i [packages]             additional packages to include after install
  -l                        enable LUKS for image
  -m [machine]              type of machine (cloud, nspawn, qemu, physical-disk, physical-path, pxe)
  -n [nameserver]           nameserver to use (default: 1.1.1.1)
  -o [path]                 output directory (nspawn, physical-path, pxe), target disk (physical-disk) or filename without extension (all others) (default: ${OUTPUT})
  -p [password]             root password (default: none)
  -s [size]                 image size (default: 10G)
  -t [path]                 temporary files directory (default: ./tmp)
  -u [username]             username for initial user (default: ansible)
  -uk [filename]            filename for SSH public key to add to initial user (default: ./id_rsa.pub)
  -uh [path]                home dir for initial user (default: /home/ansible)
  -v [version]              debian version to install (default: buster)"
  exit 0
}

function provision() {
  if [ ${FEATFORMAT} ]; then
    if [ ! -e /dev/lvm/root ]; then
      parted "${OUTPUT}" mklabel gpt
      parted "${OUTPUT}" mkpart primary fat32 1MiB 200MiB
      parted "${OUTPUT}" set 1 esp on
      mkfs.vfat -n efi "${OUTPUT}1"
      parted "${OUTPUT}" mkpart primary 200MiB 100%
      if [ ${FEATLUKS} ]; then
        cryptsetup --label luks -v luksFormat --type luks2 "${OUTPUT}2"
        cryptsetup open /dev/disk/by-label/luks luks
        vgcreate lvm /dev/mapper/luks
      else
        vgcreate lvm "${OUTPUT}2"
      fi
      lvcreate -n swap -L "$(dmidecode -t 17 | grep 'Size.*MB' | awk '{s+=$2} END {print s / 1024}')G" lvm
      mkswap -L swap /dev/lvm/swap
      lvcreate -n root -l "20%VG" lvm
      mkfs.ext4 -L root /dev/lvm/root
      lvcreate -n home -l "100%FREE" lvm
      mkfs.ext4 -L home /dev/lvm/home
    fi
    if [ ${FEATLUKS} ] && [ ! -e /dev/mapper/luks ]; then
      cryptsetup open /dev/disk/by-label/luks luks
    fi
    mount /dev/disk/by-label/root /mnt || true
    mkdir -p /mnt/boot/efi
    mount /dev/disk/by-label/efi /mnt/boot/efi || true
    mkdir -p /mnt/home
    mount /dev/disk/by-label/home /mnt/home || true
    swapon /dev/disk/by-label/swap || true
    OUTPUT=/mnt
  fi

  if [ ${FEATIMAGE} ]; then
    IMAGENAME="${OUTPUT}.${FEATIMAGEFORMAT}"
    if [ ! -e "${IMAGENAME}" ]; then
      qemu-img create -f "${FEATIMAGEFORMAT}" "${IMAGENAME}" "${FEATIMAGESIZE}"
      modprobe nbd max_part=4
      qemu-nbd -c /dev/nbd0 -f "${FEATIMAGEFORMAT}" "${IMAGENAME}"

      sleep 1

      if [ ${FEATEFI} ]; then
        parted /dev/nbd0 mklabel gpt
        parted /dev/nbd0 mkpart primary fat32 1MiB 200MiB
        parted /dev/nbd0 set 1 esp on
        parted /dev/nbd0 mkpart primary ext4 200MIB 100%
      else
        parted /dev/nbd0 mklabel msdos
        parted /dev/nbd0 mkpart primary ext4 1MiB 100%
        parted /dev/nbd0 set 1 boot on
      fi

      if [ ${FEATEFI} ]; then
        mkfs.vfat -n "efi" /dev/nbd0p1
      fi

      mkfs.ext4 -L "root" ${FEATIMAGEROOT}
      qemu-nbd -d /dev/nbd0
    fi

    qemu-nbd -c /dev/nbd0 -f "${FEATIMAGEFORMAT}" "${IMAGENAME}"
    sleep 1

    mkdir -p "${TEMPDIR}"
    mount ${FEATIMAGEROOT} "${TEMPDIR}"

    if [ ${FEATEFI} ]; then
      mkdir -p "${TEMPDIR}/boot/efi"
      mount /dev/nbd0p2 "${TEMPDIR}/boot/efi"
    fi
  fi
}

function install() {
  PACKAGES=""
  if [ "${FEATDIRECT}" ]; then
    TEMPDIR="${OUTPUT}"
  fi

  if [ "${FEATFORMAT}" ]; then
    if [ "${FEATLUKS}" ]; then
      OPTIONS="resume=LABEL=swap root=LABEL=root"
    fi
    PACKAGES="lvm2,${PACKAGES}"
  fi

  if [ "${FEATIMAGE}" ]; then
    if [ "${FEATEFI}" != yes ]; then
      PACKAGES="grub2,${PACKAGES}"
    fi
  fi

  if [ "${FEATLUKS}" ]; then
    PACKAGES="cryptsetup,cryptsetup-initramfs,${PACKAGES}"
  fi

  if [ "${FEATLINUXAMD64}" ]; then
    PACKAGES="linux-image-amd64,${PACKAGES}"
  fi

  if [ "${FEATSQUASH}" ]; then
    PACKAGES="cryptsetup,debootstrap,dosfstools,firmware-linux,firmware-iwlwifi,live-boot,lvm2,parted,${PACKAGES}"
  fi

  if [ ! -e "${TEMPDIR}/bin" ]; then
    debootstrap --arch "${ARCH}" --components=main,contrib,non-free --include apt-transport-https,ca-certificates,curl,dbus,jq,libpam-systemd,locales,openssh-server,policykit-1,python-apt,sudo,usrmerge,unzip,"${PACKAGES}" --exclude cron,ifupdown,iptables,logrotate,nano,rsyslog,"${EXCLUDE}" "${VERSION}" "${TEMPDIR}" "http://${PROXY}deb.debian.org/debian"
  fi
}

function configure() {
  # Edit sources
  cat > "${TEMPDIR}/etc/apt/sources.list" << EOF
deb http://${PROXY}deb.debian.org/debian ${VERSION} main contrib non-free
EOF
  if [ ${VERSION} = "buster" ]; then
    cat >> "${TEMPDIR}/etc/apt/sources.list" << EOF
deb http://${PROXY}deb.debian.org/debian ${VERSION}-backports main contrib non-free
deb http://${PROXY}deb.debian.org/debian ${VERSION}-updates main contrib non-free
deb http://${PROXY}security.debian.org/debian-security ${VERSION}/updates main contrib non-free
EOF
  fi

  # Dynamic hostname
  rm -f "${TEMPDIR}/etc/hostname" || true

  # Disable timesync service for containers
  if [ "${FEATCONTAINER}" ]; then
    rm "${TEMPDIR}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service" || true
  fi

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
    rm "${TEMPDIR}/etc/resolv.conf"
    echo "nameserver ${NAMESERVER}" > "${TEMPDIR}/etc/resolv.conf"
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
  for service in polkit systemd-networkd systemd-networkd-wait-online systemd-resolved; do
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
  chroot "${TEMPDIR}" useradd -c "${INITUSERNAME}" -d "${INITUSERHOME}" -mu 2000 "${INITUSERNAME}" || true
  echo '%sudo ALL=(ALL) NOPASSWD: ALL' > "${TEMPDIR}"/etc/sudoers.d/sudoers
  chroot "${TEMPDIR}" gpasswd -a "${INITUSERNAME}" sudo || true
  chroot "${TEMPDIR}" mkdir -p "${INITUSERHOME}"/.ssh
  chroot "${TEMPDIR}" mkdir -p "${INITUSERHOME}"/.ssh
  chroot "${TEMPDIR}" touch "${INITUSERHOME}"/.ssh/authorized_keys
  chroot "${TEMPDIR}" chown "${INITUSERNAME}:${INITUSERNAME}" "${INITUSERHOME}/.ssh"
  cp "${INITUSERKEY}" "${TEMPDIR}${INITUSERHOME}"/.ssh/authorized_keys

  # Set root password
  if [ "${PASSWORD}" ]; then
    echo "root:${PASSWORD}" | chpasswd -R "${TEMPDIR}"
  fi

  if [ ${FEATIMAGE} ]; then
    cat > "${TEMPDIR}/etc/systemd/system/growroot.service" << EOF
[Unit]
Description=Grow root partition

[Service]
Type=oneshot
ExecStart=/usr/sbin/parted ---pretend-input-tty /dev/vda resizepart 1 yes 100%
ExecStart=/usr/sbin/resize2fs /dev/vda1

[Install]
WantedBy=multi-user.target
EOF
    ln -s /etc/systemd/system/growroot.service "${TEMPDIR}/etc/systemd/system/multi-user.target.wants/" || true
  fi
}

function finalize() {
  chroot "${TEMPDIR}" apt clean
  if [ "${FEATEFI}" ]; then
    cat > "${TEMPDIR}/etc/fstab" << EOF
LABEL=efi /boot/efi vfat defaults 0 1
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
options ${OPTIONS} rw
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

    if [ "${FEATLUKS}" ]; then
      cat >> "${TEMPDIR}/etc/crypttab" << EOF
luks LABEL=luks none luks,initramfs
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

  if [ "${FEATIMAGE}" ]; then
    cat >> "${TEMPDIR}/etc/fstab" << EOF
LABEL=root / ext4 defaults,noatime 0 1
EOF
    if [ ! "${FEATEFI}"]; then
      cat >> "${TEMPDIR}/etc/fstab" << EOF
LABEL=root / ext4 defaults,noatime 0 1
EOF
      mount -o bind /dev "${TEMPDIR}/dev"
      mount -t proc /proc "${TEMPDIR}/proc"
      mount -t sysfs /sys "${TEMPDIR}/sys"
      sed -i 's/#GRUB_TERMINAL/GRUB_TERMINAL/g' "${TEMPDIR}/etc/default/grub"
      sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/g' "${TEMPDIR}/etc/default/grub"
      chroot "${TEMPDIR}" grub-install /dev/nbd0
      chroot "${TEMPDIR}" grub-mkconfig -o /boot/grub/grub.cfg
    fi
    umount -R "${TEMPDIR}"
    rmdir "${TEMPDIR}"
    qemu-nbd -d /dev/nbd0
  fi

  if [ "${FEATSQUASH}" ]; then
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
    mkdir -p "${OUTPUT}"
    cp "${TEMPDIR}/vmlinuz" "${OUTPUT}/vmlinuz"
    cp "${TEMPDIR}/initrd.img" "${OUTPUT}/initrd.img"
    mksquashfs "${TEMPDIR}" "${OUTPUT}/root.squashfs" -e boot
    cp -R /boot/efi/EFI "${OUTPUT}/EFI"
    mkdir -p "${OUTPUT}/loader/entries"
    cat >> "${OUTPUT}/loader/loader.conf" << EOF
default Debian
EOF
    cat >> "${OUTPUT}/loader/entries/debian.conf" << EOF
title Debian
linux /vmlinuz
initrd /initrd.img
options boot=live fromiso=/root.squashfs toram
EOF
  fi

  if [ ${FEATFORMAT} ]; then
    cat > "${TEMPDIR}/etc/fstab" << EOF
LABEL=efi /boot/efi vfat defaults 0 0
LABEL=home /home ext4 defaults 0 0
LABEL=root / ext4 defaults 0 0
LABEL=swap none swap defaults 0 0
EOF
    umount -R /mnt
    swapoff /dev/disk/by-label/swap
    vgchange -an /dev/lvm
    if [ ${FEATLUKS} ]; then
      cryptsetup close /dev/mapper/luks
    fi
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
    -a)
      PROXY="${2}/"
      shift 2
    ;;
    -b)
      OPTIONS="${2}"
      shift 2
    ;;
    -d)
      set -x
      shift 1
    ;;
    -h)
      show_usage
    ;;
    -i)
      ADDITIONAL="${2}"
      shift 2
    ;;
    -l)
      FEATLUKS=yes
      shift 1
    ;;
    -m)
      case "${2}" in
        cloud)
          FEATIMAGE=yes
          FEATLINUXAMD64=yes
        ;;
        nspawn)
          FEATCONTAINER=yes
          FEATDIRECT=yes
        ;;
        qemu)
          FEATEFI=yes
          FEATLINUXAMD64=yes
          FEATIMAGE=yes
        ;;
        physical-disk)
          FEATDIRECT=yes
          FEATEFI=yes
          FEATFORMAT=yes
          FEATLINUXAMD64=yes
        ;;
        physical-path)
          FEATDIRECT=yes
          FEATEFI=yes
          FEATLINUXAMD64=yes
        ;;
        pxe)
          FEATLINUXAMD64=yes
          FEATSQUASH=yes
        ;;
      esac
      shift 2
    ;;
    -n)
      NAMESERVER="${2}"
      shift 2
    ;;
    -o)
      OUTPUT="${2}"
      shift 2
    ;;
    -p)
      PASSWORD="${2}"
      shift 2
    ;;
    -t)
      TEMPDIR="${2}"
      shift 2
    ;;
    -u)
      INITUSERNAME="${2}"
      shift 2
    ;;
    -uh)
      INITUSERHOME="${2}"
      shift 2
    ;;
    -uk)
      INITUSERKEY="${2}"
      shift 2
    ;;
    -v)
      VERSION="${2}"
      shift 2
    ;;
    *)
      show_usage
  esac
done

if ! [ -x "$(command -v debootstrap)" ]; then
  INSTALLDEPS+=" debootstrap"
fi

if [ ${FEATEFI} ] && ! [ -x "$(command -v parted)" ]; then
  INSTALLDEPS+=" parted"
fi

if [ ${FEATIMAGE} ] && ! [ -x "$(command -v qemu-nbd)" ]; then
  INSTALLDEPS+=" qemu-utils"
fi

if [ ${FEATSQUASH} ] && ! [ -x "$(command -v mksquashfs)" ]; then
  INSTALLDEPS+=" squashfs-tools"
fi

if [ "${INSTALLDEPS}" ]; then
  apt update && apt install -y ${INSTALLDEPS}
fi

provision
install
configure
finalize
