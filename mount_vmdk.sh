#!/bin/bash

display_usage() {
  echo "$0 <dir with vmdk files>" >&2
}

exit_with_error() {
  MSG="$1"
  echo "$MSG" >&2
  exit 1
}

if [ "$#" -ne "1" ]; then
  display_usage
  exit 1
fi

VMDKDIR="$1"
if [ ! -d "$VMDKDIR" ]; then
  exit_with_error "file '$VMDKDIR' cannot be read"
fi

vmx_file() {
  VMXFILE=
  SAVEIFS=$IFS
  IFS=$(echo -en "\n\b")
  for FILE in "$VMDKDIR"/*.vmx; do
    if [ "x$VMXFILE" != "x" ]; then
      exit_with_error "found more than one vmx file, exiting..."
    fi

    VMXFILE="$FILE"
    break
  done
  IFS=$SAVEIFS
  echo $VMXFILE
}

mount_vmdk() {
  HOSTNAME="$1"
  VMDKFILE="$2"
  VMXFILE="$3"
  VOLUME="$4"
  FILENAME=$(basename "$VMDKFILE")
  echo "[+] mounting $FILENAME"

  BOUND_TO=""
  for DEVICE in /dev/nbd*; do
    if sudo qemu-nbd -r -c "${DEVICE}" "${VMDKFILE}" 2>/dev/null; then
      BOUND_TO=${DEVICE}
      break
    fi
  done

  if [ "x$BOUND_TO" == "x" ]; then
    exit_with_error "  [-] found no free nbd device to mount ${FILENAME}"
  fi

  LOOPDEVICE=$(losetup | grep "${BOUND_TO}")
  if [ "$?" -ne "0" ]; then
    LOOPDEVICE=$(sudo losetup --show -f -P -r ${BOUND_TO})
  else
    LOOPDEVICE=$(echo $LOOPDEVICE | awk '{print $1}')
  fi

  if [ "$?" -ne "0" ]; then
    exit_with_error "unable to gain loop device for '/mnt/aff/$HOSTNAME/$VMDEVICE'"
  fi

  for PARTITION in ${LOOPDEVICE}p*; do
    PARTITION_NUMBER=$(echo "$PARTITION" | sed 's/\/dev\/loop[0-9]*p\([0-9]*\)/\1/')
    MOUNT_DIR="/mnt/${HOSTNAME}/${VOLUME}/partition${PARTITION_NUMBER}"
    
    if mount | grep "$MOUNT_DIR" >/dev/null; then
      echo "  [+] $PARTITION is already mounted"
    else
      mkdir -p "$MOUNT_DIR"
      MSG=$(sudo mount -o ro,noexec,show_sys_files "$PARTITION" "$MOUNT_DIR" 2>&1)
      if [ "$?" -ne "0" ]; then
        echo "  [!] unable to mount $PARTITION"
        rmdir "$MOUNT_DIR"
      else
        echo "  [+] successfully mounted $PARTITION to $MOUNT_DIR"
      fi
    fi
  done
}

##
## make sure we are able to use sudo commands
##
sudo id >/dev/null
if [ "$?" -ne "0" ]; then
  exit_with_error "you must be able to use sudo on any commands"
fi

sudo modprobe nbd
if [ "$?" -ne "0" ]; then
  exit_with_error "unable to load qemu-nbd module"
fi

##
## mount tmpfs into /mnt, so that we can create our custom directory layout
##
if mount | grep '/mnt' >/dev/null; then
  if mount | grep 'tmpfs on /mnt type tmpfs' >/dev/null; then
    echo "/mnt is already correctly mounted"
  else
    exit_with_error "/mnt is being used by another job"
  fi
else
  sudo mount -t tmpfs tmpfs /mnt
  if [ "$?" -ne "0" ]; then
    exit_with_error "unable to mount tmpfs into root"
  fi
  mkdir /mnt/aff
fi

##
## read the hostname
##
VMXFILE="$(vmx_file)"
HOSTNAME=$(egrep "^displayName" "$VMXFILE" | cut -d '=' -f 2 | sed 's/.*"\(.*\)"/\1/' | sed -e 's/[[:space:]]*$//')
if [ "$?" -ne "0" ]; then
  exit_with_error "unable to read displayName"
fi

echo "[+] mounting files for host '$HOSTNAME'"

##
## mount images
##
pattern='(.*).fileName *= *"([^"]*\.vmdk)"'
while read -r VMXLINE; do
  if [[ "$VMXLINE" =~ $pattern ]]; then
    VMDKFILE="${BASH_REMATCH[2]}"
    VOLUME="${BASH_REMATCH[1]}"
    echo "[+] found ${VMDKFILE} as ${BASH_REMATCH[1]}"
    mount_vmdk "$HOSTNAME" "$VMDKDIR/$VMDKFILE" "$VMXFILE" "$VOLUME"
  fi
  # the line looks similar to this: nvme0:0.fileName = "Windows_AD.vmdk"
done < "$VMXFILE"
