#!/bin/bash

trap "exit 1" TERM
export TOP_PID=$$

RIP='rip'
#HAYABUSA='./hayabusa/hayabusa'
HAYABUSA_ON=false
CASEINSENSITIVE=false
SFS_ON=false
MFT=false
PREFETCH=false
TLN_PATH=$pwd

function tln2csv {
	egrep '^[0-9]+\|' | awk -F '|' '{OFS="|";print 0,$5,0,0,0,0,0,-1,$1,-1,-1}' |mactime2 -b - -d 
}

function usage {
    echo "Usage: $0 [options] [<windows_mount_dir>] [<output_dir>]"
		echo ""
		echo "Options:"
		echo "    -t <timezone>             convert timestamps from UTC to the given timezone"
		echo "    -e                        extract win event logs in squshfs container"
        echo "    -i                        switch to case-insensitive"
        echo "    -m                        parse mft (expect \$MFT in Windows Root)"
        echo "    -l                        list available timezones"
        echo "    -ha <Hayabusa_Folder>     execute hayabusa (the rules should be in the same folder as the executable)"
		echo "    -h                        show this help information"
}

POSITIONAL_ARGS=()
TIMEZONE=UTC

while [[ $# -gt 0 ]]; do
	case $1 in 
	-t)
		TIMEZONE="$2"
		shift
		shift
	;;
    -ha)
        HAYABUSA_ON=true
        HAYABUSA="$2"
        shift
        shift
    ;;
    -e)
        SFS_ON=true
        shift
    ;;
    -m)
        MFT=true
        shift
    ;;
    -p)
        PREFETCH=true
        shift
    ;;
    -i)
        CASEINSENSITIVE=true
        shift
    ;;
	-l)
		mactime2 -t list
		exit 0
	;;
	-h)
		usage
		exit 0
	;;
	*)
		POSITIONAL_ARGS+=("$1")
		shift
	;;
	esac
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

if [ $# -ne "2" ]; then
    usage
    exit 1
fi

###########################################################
#
# Check required tools
#
if ! command -v "${RIP}" &>/dev/null; then
    echo "missing RegRipper; please install RegRipper to ${RIP}" >&2
    exit 1
fi

if ! command -v "mactime2" &>/dev/null; then
    echo "missing mactime2; please run `cargo install dfir-toolkit`" >&2
    exit 1
fi

if ! command -v "mft2bodyfile" &>/dev/null; then
    echo "missing mft2bodyfile; please run `cargo install mft2bodyfile`" >&2
    exit 1
fi

if ! command -v "regdump" &>/dev/null; then
    echo "missing regdump; please run `cargo install nt_hive2`" >&2
    exit 1
fi

if [! command -v "${HAYABUSA}" &>/dev/null ] && [ $HAYABUSA_ON == true ]; then
    echo "missing hayabusa; please install hayabusa" >&2
    exit 1
fi

if [ ! command -v "mksquashfs" &>/dev/null ] && [ $SFS_ON == true ] ; then
    echo "missing squashfs; please run `sudo apt install squashfs-tools`" >&2
    exit 1
fi
###########################################################


###########################################################
#
# Checks if a file exists and is readable. If it is, this
# function prints the name of the file.
# If <fail_if_missing> evaluates to true, the functions
# aborts this script if the file does not exist or 
# if it is not readable
# 
# Usage: 
#
# check_file <filename> <fail_if_missing>
#
function check_file {
    local FILE=$1
    local FAIL_IF_MISSING=$2

    if [ -r "$FILE" ]; then
        echo "[+] found '$FILE'" >&2
        if [[ "$FILE" == *" "* ]]; then
            filename=$(basename "$FILE")
            cp "$FILE" "$TEMP_DIR"
            echo "$TEMP_DIR/$filename"
        else
            echo "$FILE"
        fi
        exit
    fi

    if $FAIL_IF_MISSING; then
        echo "[-] missing '$FILE', aborting..." >&2
        kill -s TERM $TOP_PID
    fi

    echo ""
}
###########################################################

###########################################################
#
# Usage:
#
# do_timeline <registry hive file> [<destination>]
#
# If you do not specify a destination, it will default to the
# basename of the registry hive file.
# In every case, destination will be prefixed by 'tln_' and
# suffixed by '.csv', so the remaining file will have the name
#   tln_${destination}.csv
#
function do_timeline {
    local FILE=$1
    if [ "x$2" == "x" ]; then 
        BASENAME=$(basename "$FILE")
    else
        BASENAME=$2
    fi
    
    echo "[+] creating timeline for '$BASENAME'" >&2
    
    $RIP -r "$FILE" -aT 2>/dev/null | egrep '^[0-9]+\|' | tln2csv > "$OUTDIR/tln_$BASENAME.csv"
    BASENAME=
}
###########################################################

###########################################################
#
# Usage:
#
# host_info <path of SYSTEM hive> <path of SOFTWARE hive> <path of SAM hive>
#
function host_info {
    SYSTEM="$1"
    SOFTWARE="$2"
    SAM="$3"
    ${RIP} -r "$SYSTEM" -p compname > "$OUTDIR/compname.txt"
    ${RIP} -r "$SYSTEM" -p timezone > "$OUTDIR/timezone.txt"
    ${RIP} -r "$SYSTEM" -p shutdown > "$OUTDIR/shutdown.txt"
    ${RIP} -r "$SYSTEM" -p ips > "$OUTDIR/ip.txt"
    ${RIP} -r "$SYSTEM" -p usbstor > "$OUTDIR/usbstor.txt"
    ${RIP} -r "$SYSTEM" -p mountdev2 > "$OUTDIR/mounted_devices.txt"

    ${RIP} -r "$SOFTWARE" -p msis > "$OUTDIR/installed_software.txt"
    ${RIP} -r "$SOFTWARE" -p winver > "$OUTDIR/winver.txt"
    ${RIP} -r "$SOFTWARE" -p profilelist > "$OUTDIR/profiles.txt"
    ${RIP} -r "$SOFTWARE" -p lastloggedon > "$OUTDIR/lastloggedon.txt"
    
    ${RIP} -r "$SAM" -p samparse > "$OUTDIR/samparse.txt"
    
    
}
###########################################################

###########################################################
#
# Usage:
#
# user_info <username> <path of ntuser.dat>
#
function user_info {
    USER="$1"
    NTUSER_DAT="$2"

    ${RIP} -r "$NTUSER_DAT" -p run > "$OUTDIR/${USER}_run.txt"
    ${RIP} -r "$NTUSER_DAT" -p cmdproc > "$OUTDIR/${USER}_cmdproc.txt"
}
###########################################################

###########################################################
#
# Usage:
#
# copy_user_file <username> <profiledir> <source_file_name>
#
function copy_user_file {
	USER="$1"
	PROFILEDIR="$2"
	SRCFILE="$3"
	BASE=$(echo "$SRCFILE" | cut -d . -f 1)
	EXT=$(echo "$SRCFILE" | cut -d . -f 2)
	CNT=1
	for F in `find "$PROFILEDIR" -type f -iname "$SRCFILE"`; do 
		DSTFILE="${BASE}_${USER}_${CNT}.${EXT}"

		if [ -r "$F" ]; then
			echo "[+] exfiltrating '$F' from user $USER" >&2
			cp "$F" "$DSTFILE"
		else
			echo "[-] file '$F' not found" >&2
		fi
		CNT=$(($CNT+1))
	done
}
###########################################################


###########################################################
#
# Usage:
#
# registry_timeline <hive_file>
#
function registry_timeline {
	FILE="$1"
	HIVE=$(basename "$FILE")
	if [ -r "$FILE" ]; then
		echo "[+] creating a timeline of '$HIVE'" >&2
		regdump -b "$FILE" | mactime2 -b - -d -t "$TIMEZONE" > "$OUTDIR/regtln_${HIVE}.csv"
	else
		echo "[-] file '$FILE' not found" >&2
	fi
}
###########################################################

###########################################################
#
# Usage:
#
# evtx_timeline <logs_path>
#
function evtx_timeline {
	LOGS_PATH="$1"
  echo "[+] creating windows evtx timeline" >&2
  evtx2bodyfile "$LOGS_PATH/"*.evtx | mactime2 -d -t "$TIMEZONE" | gzip -c - > "$OUTDIR/evtx.csv.gz"
}
###########################################################


###########################################################
#
# Usage:
#
# mft_timeline
#
function mft_timeline {
  echo "[+] creating mft timeline" >&2
  mft2bodyfile "$WIN_MOUNT${DATAPATHS[10]}" | mactime2 -d -t "$TIMEZONE" | gzip -c - > "$OUTDIR/mft.csv.gz"
}
###########################################################


###########################################################
#
# Usage:
#
# hayabusa <logs_path>
#
function hayabusa {
  LOGS_PATH="$1"
  echo "[+] creating hayabusa output" >&2
  cd $HAYABUSA
  ./hayabusa csv-timeline -d "$LOGS_PATH" -o "$OUTDIR/tln_hayabusa.csv" -H "$OUTDIR/tln_hayabusa_summary.html" -U -q | tee "$OUTDIR/hayabusa_overview_tln.txt"
 # ./hayabusa logon-summary -d "$LOGS_PATH" -o "$OUTDIR/hayabusa_logons" -U -Q -q
  ./hayabusa logon-summary -d "$LOGS_PATH" -U -Q -q | tee "$OUTDIR/hayabusa_overview_logons.txt"
  cd $TLN_PATH
}
###########################################################


WIN_MOUNT=`realpath "$1"`
OUTDIR=`realpath "$2"`

if [ ! -d "$WIN_MOUNT" ]; then 
    echo "'$WIN_MOUNT' is not a directory" >&2
    exit 1
fi

if [ ! -d "$OUTDIR" ]; then 
    mkdir $OUTDIR
fi

DATAPATHS=("/Windows/System32/config/SYSTEM" "/Windows/System32/config/SOFTWARE" "/Windows/System32/config/SECURITY" "/Windows/appcompat/Programs/Amcache.hve" "/Windows/AppCompat/Programs/Amcache.hve" "/Users" "/NTUSER.DAT" "/AppData/Local/Microsoft/Windows/UsrClass.dat" "ConsoleHost_history.txt" "/Windows/System32/winevt/Logs" "/\$MFT" "/Windows/Prefetch" "/Windows/System32/config/SAM")

if [ $CASEINSENSITIVE == true ]; then
    for i in "${!DATAPATHS[@]}"; do
        DATAPATHS[$i]=$(echo "${DATAPATHS[$i]}" | tr '[:upper:]' '[:lower:]')
    done        
fi

TEMP_DIR=$(mktemp -d)

SYSTEM="$(check_file "$WIN_MOUNT${DATAPATHS[0]}" true)"
SOFTWARE="$(check_file "$WIN_MOUNT${DATAPATHS[1]}" true)"
SECURITY="$(check_file "$WIN_MOUNT${DATAPATHS[2]}" true)"
#SYSCACHE="$(check_file "$WIN_MOUNT/Windows/System32/config/Syscache.hve" true)"
AMCACHE="$(check_file "$WIN_MOUNT${DATAPATHS[3]}" false)"
SAM="$(check_file "$WIN_MOUNT${DATAPATHS[12]}" true)"

if [ "x$AMCACHE" == "x" ]; then
    AMCACHE="$(check_file "$WIN_MOUNT${DATAPATHS[4]}" false)"
fi

host_info "$SYSTEM" "$SOFTWARE" "$SAM"

for F in "$SYSTEM" "$SOFTWARE" "$SECURITY"; do
    do_timeline "$F"
	registry_timeline "$F"
done

if [ "x$AMCACHE" != "x" ]; then
    do_timeline "$AMCACHE"
fi

rm -r "$TEMP_DIR"


if [ ! -d "$WIN_MOUNT${DATAPATHS[5]}" ]; then
    echo "[-] no Users directory found" >&2
else
    while IFS= read -r D; do 
        USER=$(basename $D)
        USER_DIR=$(realpath "$D")
        echo "[+] found user '$USER'"

        NTUSER_DAT=$(check_file "$USER_DIR${DATAPATHS[6]}" false)
        USRCLASS_DAT=$(check_file "$USER_DIR${DATAPATHS[7]}" false)
        if [ "x$NTUSER_DAT" != "x" ]; then
            do_timeline "$NTUSER_DAT" "${USER}_ntuser"
            else
                    echo "[-] missing file $NTUSER_DAT"
        fi
        if [ "x$USRCLASS_DAT" != "x" ]; then
            do_timeline "$USRCLASS_DAT" "${USER}_usrclass"
            else
            echo "[-] missing file $USRCLASS_DAT"
        fi

        copy_user_file "$USER" "$USER_DIR" "${DATAPATHS[8]}"

    done < <(find "$WIN_MOUNT/Users" -maxdepth 1 -mindepth 1 -type d)
fi


if [ $SFS_ON == true ]; then
    mksquashfs "$WIN_MOUNT${DATAPATHS[9]}" "$OUTDIR/evtx.sqfs"
fi

if [ $MFT == true ]; then
    mft_timeline
fi

if [ ! -d "$WIN_MOUNT${DATAPATHS[11]}" ]; then 
    echo "[-] no prefetch files found" >&2
else
    echo "[+] creating prefetch timeline" >&2
    pf2bodyfile "$WIN_MOUNT${DATAPATHS[11]}/"*.pf | mactime2 -d -t "$TIMEZONE" > "$OUTDIR/prefetch.csv"
fi

evtx_timeline "$WIN_MOUNT${DATAPATHS[9]}"

if [ $HAYABUSA_ON == true ]; then
    hayabusa "$WIN_MOUNT${DATAPATHS[9]}"
fi
