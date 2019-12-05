#!/bin/bash -x

echo "---------------- Resize persistent partition to 100% ----------------"
pnum=`cat /etc/fstab | grep -o '.*${MNT_POINT}[0-9].*persist' | grep -o '[0-9]\+' | tail -1`
if [ -z ${pnum} ]; then
    echo "No data partition found."
    exit 1
fi
/bin/umount -f /dev/${MNT_POINT}${pnum} || true
echo ", +" | /usr/sbin/sfdisk --force -N $pnum /dev/${MNT_DEV}
/usr/sbin/partx -u /dev/${MNT_DEV}
/sbin/mkfs.ext4 -F -O 64bit /dev/${MNT_POINT}${pnum}
/bin/mount /dev/${MNT_POINT}${pnum}