#!/usr/bin/env bash
set -e

IMAGE_FLAVOURS="vaillant homeassist"
KERNEL_IMAGETYPE="zImage"

MOUNT_POINT="/tmp/mntpoint"
CUR_STEP=1

usage()
{
	echo "`basename "$0"` <-p image-folder> <-d image-file> [-s image-size-gb]"
	echo "	-p image-folder	Yocto deploy folder where artifacts live"
	echo "	-d image-file	Output image file or physical device"
	echo "	-s image-size	Optional, image size in GB"
	echo "	-k ssh-folder	Optional, path to pre-generated ssh keys/authorized_keys"

	exit 1
}

print_step()
{
	local caption=$1
	echo "###############################################################################"
	echo "Step $CUR_STEP: $caption"
	echo "###############################################################################"
	((CUR_STEP++))
}

###############################################################################
# Machine detection
###############################################################################

detect_flavour()
{
	local db_base_folder=$1

	print_step "Detecting machine and image flavour"

	local image_flavour=""
	for f in $IMAGE_FLAVOURS ; do
		image_flavour=`find $db_base_folder \( -iname \*cpio.gz -o -iname \*tar.bz2 \) -type f -exec basename {} \; | grep $f` || true
		if [ ! -z "$image_flavour" ]; then
			export IMAGE_FLAVOUR=$f
			break
		fi
	done
	if [ -z "$IMAGE_FLAVOUR" ]; then
		echo "Cannot detect image flavour out of $IMAGE_FLAVOURS"
		usage
	fi
	echo "Image flavour is $IMAGE_FLAVOUR"

	local Image=`find $db_base_folder -name ${KERNEL_IMAGETYPE}`
	local image_dest=`readlink $Image`
	local machine=`echo $image_dest | sed 's/^.*\(raspberry.*\).*$/\1/' | sed -e 's/\([^\.]*\).*/\1/;s/-[0-9]*$//'`
	if [ -z "$machine" ]; then
		echo "Cannot detect MACHINE type"
		usage
	fi
	export MACHINE=$machine

	echo "Machine is $MACHINE"
}

###############################################################################
# Inflate image
###############################################################################
inflate_image()
{
	local dev=$1
	local size_gb=$2

	print_step "Inflate image"

	if  [ -b "$dev" ] ; then
		echo "Using physical block device $dev"
		return 0
	fi

	echo "Inflating image file at $dev of size ${size_gb}GB"

	local inflate=1
	if [ -e $1 ] ; then
		echo ""
		read -r -p "File $dev exists, remove it? [y/N]:" yesno
		case "$yesno" in
		[yY])
			rm -f $dev || exit 1
		;;
		*)
			echo "Reusing existing image file"
			inflate=0
		;;
		esac
	fi
	if [[ $inflate == 1 ]] ; then
		dd if=/dev/zero of=$dev bs=1M count=$(($size_gb*1024)) || exit 1
	fi
}

###############################################################################
# Partition image
###############################################################################
define_partitions()
{
	PART_BOOT_START=1
	PART_BOOT_END=$((PART_BOOT_START+256))
	PART_BOOT_LABEL=boot
	PART_BOOT=1
	# Logical partitions start after the primary ones (4 for MSDOS),
	# so the first logical will be /dev/XXXp5
	PART_OVERLAY=5
	PART_SECRET=6
	PART_DATA=7

	case $IMAGE_FLAVOUR in
		vaillant)
			PART_OVERLAY_START=$PART_BOOT_END
		;;
		homeassist)
			PART_ROOTFS=2

			PART_ROOTFS_START=$PART_BOOT_END
			PART_ROOTFS_END=$((PART_2_ROOTFS_START+2048))
			PART_ROOTFS_LABEL=rootfs

			PART_OVERLAY_START=$PART_ROOTFS_END
		;;
		*)
			echo "No partition definition exists for $IMAGE_FLAVOUR"
			exit 1
		;;
	esac

	PART_OVERLAY_END=$((PART_OVERLAY_START+1024))
	PART_OVERLAY_LABEL=overlay

	PART_SECRET_START=$PART_OVERLAY_END
	PART_SECRET_END=$((PART_SECRET_START+256))
	PART_SECRET_LABEL=secret

	PART_DATA_START=$PART_SECRET_END
	PART_DATA_LABEL=data
}

partition_image()
{
	print_step "Make partitions"

	parted -s $1 mklabel msdos

	# Skip first 1MiB
	parted -s $1 mkpart primary fat32 ${PART_BOOT_START}MB ${PART_BOOT_END}MB

	if [ ! -z ${PART_ROOTFS_START} ]; then
		parted -s $1 mkpart primary ext4 ${PART_ROOTFS_START}MB ${PART_ROOTFS_END}MB
	fi

	# All the rest will be logical partitions
	parted -s $1 mkpart extended ${PART_OVERLAY_START}MB 100%

	parted -s $1 mkpart logical ext4 ${PART_OVERLAY_START}MB ${PART_OVERLAY_END}MB
	parted -s $1 mkpart logical ext4 ${PART_SECRET_START}MB ${PART_SECRET_END}MB
	parted -s $1 mkpart logical ext4 ${PART_DATA_START}MB 100%

	partprobe $1
}

###############################################################################
# Make file system
###############################################################################

mkfs_one()
{
	local img_output_file=$1
	local loop_base=$2
	local part=$3
	local label=$4
	local loop_dev="${loop_base}p${part}"

	print_step "Making ext4 filesystem for $label"

	mkfs.ext4 -O ^64bit -F $loop_dev -L $label
}

mkfs_boot()
{
	local img_output_file=$1
	local loop_base=$2
	local part=$PART_BOOT
	local label=BOOT
	local loop_dev="${loop_base}p${part}"

	print_step "Making FAT32 filesystem for $label"

	mkfs.vfat -F 32 $loop_dev -n $label
}

mkfs_rootfs()
{
	local img_output_file=$1
	local loop_dev=$2

	mkfs_one $img_output_file $loop_dev $PART_ROOTFS $PART_ROOTFS_LABEL
}

mkfs_overlay()
{
	local img_output_file=$1
	local loop_dev=$2

	mkfs_one $img_output_file $loop_dev $PART_OVERLAY $PART_OVERLAY_LABEL
}

mkfs_secret()
{
	local img_output_file=$1
	local loop_dev=$2

	mkfs_one $img_output_file $loop_dev $PART_SECRET $PART_SECRET_LABEL
}

mkfs_data()
{
	local img_output_file=$1
	local loop_dev=$2

	mkfs_one $img_output_file $loop_dev $PART_DATA $PART_DATA_LABEL
}

mkfs_image()
{
	local img_output_file=$1
	local loop_dev=$2
	losetup -P $loop_dev $img_output_file

	mkfs_boot $img_output_file $loop_dev
	if [ ! -z ${PART_ROOTFS_START} ]; then
		mkfs_rootfs $img_output_file $loop_dev
	fi
	mkfs_overlay $img_output_file $loop_dev
	mkfs_secret $img_output_file $loop_dev
	mkfs_data $img_output_file $loop_dev
}

###############################################################################
# Mount partition
###############################################################################

mount_part()
{
	local loop_base=$1
	local img_output_file=$2
	local part=$3
	local mntpoint=$4
	local loop_dev=${loop_base}p${part}

	mkdir -p "${mntpoint}" || true
	mount $loop_dev "${mntpoint}"
}

umount_part()
{
	local loop_base=$1
	local part=$2
	local loop_dev=${loop_base}p${part}

	umount $loop_dev
}

###############################################################################
# Unpack
###############################################################################

unpack_part_from_cpio()
{
	local db_base_folder=$1
	local loop_base=$2
	local img_output_file=$3
	local part=$4
	local rootfs_basename=$5
	local loop_dev=${loop_base}p${part}

	local rootfs=`find $db_base_folder -name "rootfs-$rootfs_basename.cpio.gz"`

	echo "Root filesystem is at $rootfs"

	mount_part $loop_base $img_output_file $part $MOUNT_POINT

	pushd . > /dev/null
	cd $MOUNT_POINT

        gzip -cd $rootfs | cpio -imd --quiet

	popd > /dev/null

	umount_part $loop_base $part
}

unpack_part_from_tar()
{
	local db_base_folder=$1
	local loop_base=$2
	local img_output_file=$3
	local part=$4
	local rootfs_basename=$5
	local loop_dev=${loop_base}p${part}

	local rootfs=`find $db_base_folder -name "*$MACHINE*$rootfs_basename.tar.bz2"`

	echo "Root filesystem is at $rootfs"

	mount_part $loop_base $img_output_file $part $MOUNT_POINT

	tar --extract --bzip2 --numeric-owner --preserve-permissions --preserve-order --totals \
		--xattrs-include='*' --directory="${MOUNT_POINT}" --file=$rootfs

	umount_part $loop_base $part
}

###############################################################################
# This comes from meta-rpi
###############################################################################
get_bootfiles()
{
	case "${MACHINE}" in
		raspberrypi|raspberrypi0|raspberrypi0-wifi|raspberrypi-cm)
			DTBS="bcm2708-rpi-0-w.dtb \
			      bcm2708-rpi-b.dtb \
			      bcm2708-rpi-b-plus.dtb \
			      bcm2708-rpi-cm.dtb"
		;;
		raspberrypi2|raspberrypi3|raspberrypi-cm3)
			DTBS="bcm2709-rpi-2-b.dtb \
			      bcm2710-rpi-3-b.dtb \
			      bcm2710-rpi-cm3.dtb"
		;;
		*)
			echo "Invalid MACHINE: ${MACHINE}"
			exit 1
	esac

	BOOTLDRFILES="bootcode.bin \
		      cmdline.txt \
		      config.txt \
		      fixup_cd.dat \
		      fixup.dat \
		      fixup_db.dat \
		      fixup_x.dat \
		      start_cd.elf \
		      start_db.elf \
		      start.elf \
		      start_x.elf"

	export DTBS BOOTLDRFILES
}

unpack_boot()
{
	local db_base_folder=$1
	local loop_base=$2
	local img_output_file=$3

	local part=$PART_BOOT

	print_step "Unpacking BOOT"

	local Image=`find $db_base_folder -name ${KERNEL_IMAGETYPE}`
	local initrd=`find $db_base_folder -name initrd`
	local deploy_dir=`dirname $Image`

	echo "$IMAGE_FLAVOUR kernel image is at $Image"
	if [ ! -z ${initrd} ]; then
		echo "Found initramfs at $initrd"
	fi

	get_bootfiles

	mount_part $loop_base $img_output_file $part $MOUNT_POINT

	mkdir "${MOUNT_POINT}/overlays" || true

	cp -L $Image "${MOUNT_POINT}/"
	if [ ! -z ${initrd} ]; then
		cp -L $initrd "${MOUNT_POINT}/"
	fi

	for f in $BOOTLDRFILES ; do
		cp -L $deploy_dir/bcm2835-bootfiles/$f "${MOUNT_POINT}/"
	done

	for f in $DTBS ; do
		cp -L $deploy_dir/$f "${MOUNT_POINT}/"
	done

	for f in $deploy_dir/${KERNEL_IMAGETYPE}-*.dtbo; do
		if [ -L $f ]; then
			fname="${f##*/}"
			frename="${fname#${KERNEL_IMAGETYPE}-}"
			cp "$f" "${MOUNT_POINT}/overlays/$frename"
		fi
	done

	umount_part $loop_base $part
}

###############################################################################
# This is from /usr/libexec/openssh/sshd_check_keys
###############################################################################
generate_key() {
	local FILE=$1
	local TYPE=$2
	local DIR="$(dirname "$FILE")"

	ssh-keygen -q -f "${FILE}.tmp" -N '' -t $TYPE

	# Atomically rename file public key
	mv -f "${FILE}.tmp.pub" "${FILE}.pub"

	# This sync does double duty: Ensuring that the data in the temporary
	# private key file is on disk before the rename, and ensuring that the
	# public key rename is completed before the private key rename, since we
	# switch on the existence of the private key to trigger key generation.
	# This does mean it is possible for the public key to exist, but be garbage
	# but this is OK because in that case the private key won't exist and the
	# keys will be regenerated.
	#
	# In the event that sync understands arguments that limit what it tries to
	# fsync(), we provided them. If it does not, it will simply call sync()
	# which is just as well
	sync "${FILE}.pub" "$DIR" "${FILE}.tmp"

	mv "${FILE}.tmp" "$FILE"

	# sync to ensure the atomic rename is committed
	sync "$DIR"
}

unpack_secret_gen_keys()
{
	local loop_base=$2
	local img_output_file=$3
	local ssh_keys=$4
	local part=$PART_SECRET

	mount_part $loop_base $img_output_file $part $MOUNT_POINT

	# Move $MOUNT_POINT/mnt/secret to $MOUNT_POINT
	mv ${MOUNT_POINT}/mnt/secret/* ${MOUNT_POINT}/
	rm -rf ${MOUNT_POINT}/mnt

	print_step "Installing ssh keys"

	local ssh_dir="${MOUNT_POINT}/ssh"
	mkdir -p "$ssh_dir" || true

	if [ -z "${ssh_keys}" ]; then

		echo "Generating ssh RSA key..."
		generate_key $ssh_dir/ssh_host_rsa_key rsa

		echo "Generating ssh ECDSA key..."
		generate_key $ssh_dir/ssh_host_ecdsa_key ecdsa

		echo "Generating ssh DSA key..."
		generate_key $ssh_dir/ssh_host_dsa_key dsa

		echo "Generating ssh ED25519 key..."
		generate_key $ssh_dir/ssh_host_ed25519_key ed25519
	else
		echo "Using keys at $ssh_keys"
		cp -rf $ssh_keys/* $ssh_dir/
	fi

	umount_part $loop_base $part
}

unpack_rootfs()
{
	local db_base_folder=$1
	local loop_dev=$2
	local img_output_file=$3

	print_step  "Unpacking root file system"

	unpack_part_from_tar $db_base_folder $loop_dev $img_output_file $PART_ROOTFS rootfs
}

unpack_secret()
{
	local db_base_folder=$1
	local loop_dev=$2
	local img_output_file=$3

	print_step  "Unpacking secret file system"

	unpack_part_from_cpio $db_base_folder $loop_dev $img_output_file $PART_SECRET secret
}

unpack_overlay()
{
	local db_base_folder=$1
	local loop_dev=$2
	local img_output_file=$3

	print_step  "Unpacking overlay file system"

	unpack_part_from_cpio $db_base_folder $loop_dev $img_output_file $PART_OVERLAY overlay
}

unpack_image()
{
	local db_base_folder=$1
	local loop_dev=$2
	local img_output_file=$3
	local ssh_keys=$4

	unpack_boot $db_base_folder $loop_dev $img_output_file
	if [ ! -z ${PART_ROOTFS_START} ]; then
		unpack_rootfs $db_base_folder $loop_dev $img_output_file
	fi
	unpack_overlay $db_base_folder $loop_dev $img_output_file
	unpack_secret $db_base_folder $loop_dev $img_output_file
	unpack_secret_gen_keys $db_base_folder $loop_dev $img_output_file $ssh_keys
}

###############################################################################
# Common
###############################################################################

make_image()
{
	local db_base_folder=$1
	local img_output_file=$2
	local image_sg_gb=${3:-5}
	local ssh_keys=${4:-}
	local loop_dev=`losetup --find`

	print_step "Preparing image at ${img_output_file}"

	if [ ! -d "${MOUNT_POINT}" ]; then
		mkdir "${MOUNT_POINT}"
	else
		umount -f ${MOUNT_POINT} || true
	fi
	ls ${img_output_file}?* | xargs -n1 umount -l -f || true

	inflate_image $img_output_file $image_sg_gb
	partition_image $img_output_file
	mkfs_image $img_output_file $loop_dev
	unpack_image $db_base_folder $loop_dev $img_output_file $ssh_keys

	sync
	losetup -d $loop_dev || true
	print_step "Done"
}

print_step "Parsing input parameters"

while getopts ":p:d:s:u:k:" opt; do
	case $opt in
		p) ARG_DEPLOY_PATH="$OPTARG"
		;;
		d) ARG_DEPLOY_DEV="$OPTARG"
		;;
		s) ARG_IMG_SIZE_GB="$OPTARG"
		;;
		k)
			ARG_SSH_KEYS_PATH="$OPTARG"
			HAVE_ARG_SSH_KEYS=1
		;;
		\?) echo "Invalid option -$OPTARG" >&2
		exit 1
		;;
	esac
done

if [ -z "${ARG_DEPLOY_PATH}" ]; then
	echo "No path to deploy directory passed with -p option"
	usage
fi

detect_flavour "$ARG_DEPLOY_PATH"
define_partitions

if [ -z "${ARG_DEPLOY_DEV}" ]; then
	echo "No device/file name passed with -d option"
	usage
fi

if [ "$HAVE_ARG_SSH_KEYS" = 1 ] && [ -z "${ARG_SSH_KEYS_PATH}" ]; then
	echo "No path with ssh keys/authorized_keys passed with -k option"
	usage
fi

echo "Using deploy path: \"$ARG_DEPLOY_PATH\""
echo "Using device     : \"$ARG_DEPLOY_DEV\""
echo "Using SSH keys at: \"$ARG_SSH_KEYS_PATH\""

make_image "$ARG_DEPLOY_PATH" "$ARG_DEPLOY_DEV" "$ARG_IMG_SIZE_GB" "$ARG_SSH_KEYS_PATH"

