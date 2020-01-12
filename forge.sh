#!/bin/bash
set -eo pipefail

ARCH="amd64"
EXCLUDE=""
FEATCONTAINER=""
FEATDIRECT=""
FEATEFI=""
FEATLINUXAMD64=""
FEATIMAGE=""
FEATIMAGEFORMAT="qcow2"
FEATIMAGESIZE="10G"
FEATIMAGEROOT="/dev/nbd0p1"
FEATSQUASH=""
INITUSERHOME="/var/lib/salt"
INITUSERKEY="./id_rsa.pub"
INITUSERNAME="salt"
INSTALLDEPS=""
OUTPUT="./debian10"
PASSWORD="password"
PROXY=""
TEMPDIR="$(pwd)/tmp"

function show_usage() {
		echo "Usage: $0 [arguments]

Arguments:
	-a [apt-cacher-address]   apt-cacher-ng proxy
	-d                        enable debugging
	-f                        image format (default: qcow2)
	-h                        show help
	-i [packages]             additional packages to include
	-l                        enable LUKS for image
	-m [machine]              type of machine (cloud, nspawn, qemu, physical, pxe)
	-o [path]                 output directory (nspawn, pxe) or filename without extension (all others) (default: ${OUTPUT})
	-p [password]             root password (default: password)
	-s [size]                 image size (default: 10G)
	-t [path]                 temporary files directory (default: ./tmp)
	-u [username]             username for initial user (default: salt)
	-uk [filename]            filename for SSH public key to add to initial user (default: ./id_rsa.pub)
	-uh [path]                home dir for initial user (default: /var/lib/salt)"
	exit 0
}

function provision() {
	if [ ${FEATIMAGE} ]; then
		INCLUDE="parted,${INCLUDE}"
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
				INCLUDE="grub2,${INCLUDE}"
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
	if [ "${FEATDIRECT}" ]; then
		TEMPDIR="${OUTPUT}"
	fi

	if [ "${FEATLINUXAMD64}" ]; then
		INCLUDE="linux-image-amd64,${INCLUDE}"
	fi

	if [ "${FEATSQUASH}" ]; then
		INCLUDE="cryptsetup,debootstrap,dosfstools,live-boot,lvm2,${INCLUDE}"
	fi

	if [ ! -e "${TEMPDIR}"/bin ]; then
		debootstrap --arch "${ARCH}" --include apt-transport-https,ca-certificates,curl,dbus,jq,locales,openssh-server,policykit-1,python-apt,sudo,usrmerge,unzip,"${INCLUDE}" --exclude cron,ifupdown,iptables,logrotate,nano,rsyslog,"${EXCLUDE}" buster "${TEMPDIR}" "http://${PROXY}deb.debian.org/debian"
	fi
}

function configure() {
	rm "${TEMPDIR}/etc/hostname" || true

	if [ "${FEATCONTAINER}" ]; then
		rm "${TEMPDIR}/etc/systemd/system/sysinit.target.wants/systemd-timesyncd.service" || true
	fi

	cat > "${TEMPDIR}/usr/sbin/policy-rc.d" << EOF
exit 101
EOF

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
	cat > "${TEMPDIR}/etc/systemd/resolved.conf.d/fallback.conf" << EOF
[Resolve]
FallbackDNS=1.1.1.1
EOF

	# Edit sources
	cat > "${TEMPDIR}/etc/apt/sources.list" << EOF
deb http://${PROXY}deb.debian.org/debian buster main contrib non-free
deb http://${PROXY}deb.debian.org/debian buster-backports main contrib non-free
deb http://${PROXY}deb.debian.org/debian buster-updates main contrib non-free
deb http://${PROXY}security.debian.org/debian-security buster/updates main contrib non-free
EOF

	# Create user
	chroot "${TEMPDIR}" useradd -c "${INITUSERNAME}" -d "${INITUSERHOME}" -mu 2000 "${INITUSERNAME}" || true
	chroot "${TEMPDIR}" groupadd -g 3000 admins || true
	echo '%admins ALL=(ALL) NOPASSWD: ALL' > "${TEMPDIR}"/etc/sudoers.d/sudoers
	chroot "${TEMPDIR}" gpasswd -a "${INITUSERNAME}" admins || true
	chroot "${TEMPDIR}" mkdir -p "${INITUSERHOME}"/.ssh
	chroot "${TEMPDIR}" mkdir -p "${INITUSERHOME}"/.ssh
	chroot "${TEMPDIR}" touch "${INITUSERHOME}"/.ssh/authorized_keys
	chroot "${TEMPDIR}" chown "${INITUSERNAME}:${INITUSERNAME}" "${INITUSERHOME}/.ssh"
	cp "${INITUSERKEY}" "${TEMPDIR}${INITUSERHOME}"/.ssh/authorized_keys

	# Set root password
	echo "root:${PASSWORD}" | chpasswd -R "${TEMPDIR}"

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
	if [ "${FEATEFI}" ]; then
		# Setup EFI copy
		cat > "${TEMPDIR}/etc/systemd/system/efi.service" << EOF
[Unit]
Description=Copy initramfs and vmlinuz to EFI System Partitions

[Service]
Type=oneshot
ExecStart=/bin/cp /initrd.img /boot/efi/initrd.img
ExecStart=/bin/cp /vmlinuz /boot/efi/vmlinuz
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

		ln -s /etc/systemd/system/efi.path "${TEMPDIR}/etc/systemd/system/multi-user.target.wants/" || true
		
		# Setup systemd-bootd
		if [ ! -e "${TEMPDIR}/boot/efi/loader" ]; then
			bootctl --path "${TEMPDIR}/boot/efi" install
		fi
		
		echo "default debian" > "${TEMPDIR}/boot/efi/loader/loader.conf"
		
		cat > "${TEMPDIR}/boot/efi/loader/entries/debian.conf" << EOF
title Debian
linux /vmlinuz
initrd /initrd.img
EOF

		if [ "${LUKS}" = "yes" ]; then
			cat >> "${TEMPDIR}/boot/efi/loader/entries/debian.conf" << EOF
options cryptdevice=LABEL=luks:luks resume=LABEL=swap root=LABEL=root rw
EOF

			cat >> "${TEMPDIR}/etc/crypttab" << EOF
luks LABEL=luks none luks
EOF

			update-initramfs -u
		else
			cat >> "${TEMPDIR}/boot/efi/loader/entries/debian.conf" << EOF
options console=tty0 console=ttyS0 elevator=noop root=LABEL=root rw
EOF
		fi

		cp "${TEMPDIR}/initrd.img" "${TEMPDIR}/boot/efi/initrd.img"
		cp "${TEMPDIR}/vmlinuz" "${TEMPDIR}/boot/efi/vmlinuz"
	fi

	if [ "${FEATIMAGE}" ]; then
		if [ "${FEATEFI}" ]; then
			cat > "${TEMPDIR}/etc/fstab" << EOF
LABEL=efi /boot/efi vfat defaults 0 1
LABEL=root / ext4 defaults,noatime 0 1
EOF
			umount /dev/nbd0p2
		else
			cat > "${TEMPDIR}/etc/fstab" << EOF
LABEL=root / ext4 defaults,noatime 0 1
EOF
			mount -o bind /dev "${TEMPDIR}/dev"
			mount -t proc /proc "${TEMPDIR}/proc"
			mount -t sysfs /sys "${TEMPDIR}/sys"
			sed -i 's/#GRUB_TERMINAL/GRUB_TERMINAL/g' "${TEMPDIR}/etc/default/grub"
			sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=""/g' "${TEMPDIR}/etc/default/grub"
			sed -i 's/GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0"/g' "${TEMPDIR}/etc/default/grub"
			chroot "${TEMPDIR}" grub-install /dev/nbd0
			chroot "${TEMPDIR}" grub-mkconfig -o /boot/grub/grub.cfg
		fi
		umount -R "${TEMPDIR}"
		rmdir "${TEMPDIR}"
		qemu-nbd -d /dev/nbd0
	fi

	if [ "${FEATSQUASH}" ]; then
		cp /srv/salt/create_host.sh "${TEMPDIR}/root"
		echo -e "root\nroot" | passwd -R "${TEMPDIR}" root
		mksquashfs "${TEMPDIR}" "${OUTPUT}/root.squashfs" -e boot
		cp -R /boot/efi/EFI "${TEMPDIR}/EFI"
		mkdir -p "${TEMPDIR}/loader/entries"
		cat >> "${TEMPDIR}/loader/loader.conf" << EOF
default Debian
EOF
		cat >> "${TEMPDIR}/loader/entries/debian.conf" << EOF
title Debian
linux /vmlinuz
initrd /initrd.img
options boot=live fromiso=/root.squashfs toram
EOF
		cp "${TEMPDIR}/initrd.img" "${OUTPUT}/initrd.img"
		cp "${TEMPDIR}/vmlinuz" "${OUTPUT}/vmlinuz"
		rm -rf "${TEMPDIR}"
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
		-d)
			set -x
			shift 1
		;;
		-h)
			show_usage
		;;
		-i)
			INCLUDE="${2}"
			shift 2
		;;
		-l)
			LUKS=yes
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
				physical)
					FEATDIRECT=yes
					FEATEFI=yes
					FEATLINUXAMD64=yes
				;;
				pxe)
					FEATLINUXAMD64=yes
					FEATSQUASH=yes
				;;
			esac
			TYPE="${2}"
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
