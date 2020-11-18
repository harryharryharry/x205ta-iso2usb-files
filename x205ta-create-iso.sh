#!/usr/bin/env bash

if [[ -z $1 ]]
then
	echo "Supply linux iso as parameter: $0 /path/to/linux.iso"
	exit 1
fi

## If anything goes awry, abort script
set -euo pipefail

## Clean up some mounts/directories the script might have made if the script is ended (prematurely or not).
function cleanup {
	rm -rf "${tmp_work_dir}" || /bin/true
	umount "${tmp_mount_dir}" || /bin/true
	rm -rf "${tmp_mount_dir}" || /bin/true
	umount "${tmp_x205ta_efi_dir}" || /bin/true
	rm -rf "${tmp_x205ta_efi_dir}" || /bin/true
	umount "${tmp_original_efi_dir}" || /bin/true
	rm -rf "${tmp_original_efi_dir}" || /bin/true
	rm -rf /tmp/grub.cfg || /bin/true
}
trap "cleanup" SIGHUP SIGINT SIGTERM EXIT

## Perform some checks to ensure the script can run properly
if [[ $EUID != 0 ]]
then
	echo "Script needs root to mount iso."
	exit 1
fi

if [[ ! -f /usr/lib/grub/i386-efi/modinfo.sh ]]
then
	echo "Aborting: i386-efi grub-libraries (/usr/lib/grub/i386-efi) missing"
	exit 1
fi

if [[ -f /usr/share/syslinux/isohdpfx.bin ]]
then
	isohdpfx_bin="/usr/share/syslinux/isohdpfx.bin"
elif [[ -f /usr/lib/syslinux/bios/isohdpfx.bin ]]
then
	isohdpfx_bin="/usr/lib/syslinux/bios/isohdpfx.bin"
elif [[ -f /usr/lib/ISOLINUX/isohdpfx.bin ]]
then
	isohdpfx_bin="/usr/lib/ISOLINUX/isohdpfx.bin"
else
	echo "Aborting: isohdpfx.bin not found, please install syslinux and make sure this script points to isohdpfx.bin"
	exit 1
fi

if [[ -f /usr/bin/grub2-mkstandalone ]]
then
	grub_mkstandalone="/usr/bin/grub2-mkstandalone"
elif [[ -f /usr/bin/grub-mkstandalone ]]
then
	grub_mkstandalone="/usr/bin/grub-mkstandalone"
else
	grub_mkstandalone="/usr/bin/grub-emkstandalone"
fi

required_binaries=( isoinfo mkdosfs xorriso rsync readlink ${grub_mkstandalone} )
binaries_are_missing=false
for i in "${required_binaries[@]}"
do
	command -v "${i}" >/dev/null 2>&1 || { echo >&2 "This script needs $i but it's not installed."; binaries_are_missing=true; }
done

if $binaries_are_missing
then
	echo "Aborting, some required binaries are missing"
	exit 1
fi

## Set some variables with info regarding the iso and the directory the script is in
iso_label=$(isoinfo -d -i $1 | sed -n 's/Volume id: //p')
script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

## create temporary directories where the script is allowed to perform its business
tmp_mount_dir=$(mktemp -d -t x205ta-mount-XXXXXXXXXX)
tmp_work_dir=$(mktemp -d -t x205ta-work-XXXXXXXXXX)
tmp_original_efi_dir=$(mktemp -d -t x205ta-efi-original-XXXXXXXXXX)
tmp_x205ta_efi_dir=$(mktemp -d -t x205ta-efi-XXXXXXXXXX)

## Mount iso and copy its contents to a temporary directory
mount -o loop "${1}" "${tmp_mount_dir}"
rsync -a "${tmp_mount_dir}"/. "${tmp_work_dir}"

## Add a bootia32.efi (which the script will generate) to the original iso's efi.img to allow booting from a 32-bit efi device
if [[ "${iso_label}" == openSUSE* ]]
then
	efi_original_from_iso_location=$(find "${tmp_work_dir}" -type f -name 'efi' | head -n1)
else
	efi_original_from_iso_location=$(find "${tmp_work_dir}" -type f -name '*efi*img*' | head -n1)
fi

mount -o loop "${efi_original_from_iso_location}" "${tmp_original_efi_dir}"
cp -a "${tmp_original_efi_dir}"/* "${tmp_x205ta_efi_dir}"
umount "${tmp_original_efi_dir}"
dd if=/dev/zero of="${efi_original_from_iso_location}" bs=1M count=15
mkdosfs -F 12 "${efi_original_from_iso_location}"
mount -o loop "${efi_original_from_iso_location}" "${tmp_original_efi_dir}"
cp -a "${tmp_x205ta_efi_dir}"/* "${tmp_original_efi_dir}"

## Make grub.cfg aware that all files it references are located on hd0 (being the usb stick).
grub_cfg_location=$(find "${tmp_work_dir}" -name 'grub.cfg' | head -n1)
sed -i '1 i\set root=(hd0)' "${grub_cfg_location}"
echo "search.fs_label ${iso_label} root hd0,msdos2" > /tmp/grub.cfg
echo "configfile (hd0)/${grub_cfg_location#*/*/*/}" >> /tmp/grub.cfg

## Generate bootia32.efi to allow booting from a 32-bit efi device
"${grub_mkstandalone}" -d /usr/lib/grub/i386-efi/ -O i386-efi --modules="part_gpt part_msdos" --fonts="unicode" --themes="" \
	-o "${tmp_original_efi_dir}/efi/boot/bootia32.efi" "boot/grub/grub.cfg=/tmp/grub.cfg"

umount "${efi_original_from_iso_location}"

pushd "${tmp_work_dir}"
	## Create modified iso
	if [[ "${iso_label}" == MANJARO* || "${iso_label}" == *buntu*20.10* || "${iso_label}" == MX-Live ]]
	then
		xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "${iso_label}" \
                        -eltorito-boot boot/grub/i386-pc/eltorito.img -eltorito-catalog boot.catalog \
                        -no-emul-boot -boot-load-size 4 -boot-info-table -isohybrid-mbr "${isohdpfx_bin}" \
                        -eltorito-alt-boot -e "${efi_original_from_iso_location#*/*/*/}" -no-emul-boot -isohybrid-gpt-basdat \
                        -output "${script_dir}"/"${1/#/x205ta-}" .
	elif [[ "${iso_label}" == openSUSE* ]]
	then
		xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "${iso_label}" \
                        -eltorito-boot boot/x86_64/loader/isolinux.bin \
                        -no-emul-boot -boot-load-size 4 -boot-info-table -isohybrid-mbr "${isohdpfx_bin}" \
                        -eltorito-alt-boot -e "${efi_original_from_iso_location#*/*/*/}" -no-emul-boot -isohybrid-gpt-basdat \
                        -output "${script_dir}"/"${1/#/x205ta-}" .
	else
		echo "[ WARN ] Not recognizing iso label, using default xorriso-command to build iso. This may fail !!!"
		xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -volid "${iso_label}" \
                        -eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat \
                        -no-emul-boot -boot-load-size 4 -boot-info-table -isohybrid-mbr "${isohdpfx_bin}" \
                        -eltorito-alt-boot -e "${efi_original_from_iso_location#*/*/*/}" -no-emul-boot -isohybrid-gpt-basdat \
                        -output "${script_dir}"/"${1/#/x205ta-}" .
	fi
popd

## Set ownership and group permissions to the created iso (otherwise it'll be owned by root, which is annoying).
chown $(who am i | awk '{print $1}'):$(who am i | awk '{print $1}') "${script_dir}"/"${1/#/x205ta-}"

exit 0
