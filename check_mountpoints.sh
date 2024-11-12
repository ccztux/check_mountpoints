#!/usr/bin/env bash

# --------------------------------------------------------------------
# **** BEGIN LICENSE BLOCK *****
#
# Version: MPL 2.0
#
# echocat check_mountpoints.sh, Copyright (c) 2011-2021 echocat
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# **** END LICENSE BLOCK *****
# --------------------------------------------------------------------

# --------------------------------------------------------------------
# Check if all specified nfs/cifs/davfs mounts exist and if they are correct implemented.
# That means we check /etc/fstab, the mountpoints in the filesystem and if they
# are mounted. It is written for Linux, uses proc-Filesystem and was tested on
# Debian, OpenSuse 10.1 10.2 10.3 11.0, SLES 10.1 11.1, RHEL/CentOS, FreeBSD and solaris
#
# @author: Daniel Werdermann / dwerdermann@web.de
# @projectsite: https://github.com/echocat/nagios-plugin-check_mountpoints
# @version: 2.7
# @date: 2021-11-26
#
# changes 2.7
#  - new flag -f to check for fs type
# changes 2.6
#  - check only dataset type filesystem on zfs
# changes 2.5
#  - add -E flag to exclude path
#  - add yas3fs
# changes 2.4
#  - add support for ext2
# changes 2.3
#  - add support for btrfs
# changes 2.2
#  - add support for ceph
# changes 2.1
#  - clean output when mount point is stalled
# changes 2.0
#  - add support for FreeBSD
#  - ignore trailing slashes on mounts
# changes 1.22
#  - add support for ext3, ext4, auto
# changes 1.21
#  - add support for lustre fs
# changes 1.20
#  - better check on write test
# changes 1.19
#  - for write test, use filename, which is less prone to race conditions
# changes 1.18
#  - write check respects stale timeout now
# changes 1.17
#  - add support for ocfs2
# changes 1.16
#  - minor English fixes
# changes 1.15
#  - fix bad bug in MTAB check
# changes 1.14
#  - better support for HP-UX, Icinga
#  - cleanup writecheck file after check
# changes 1.13
#  - add support for glusterfs
# changes 1.12
#  - add LIBEXEC path for OpenCSW-installed nagios in Solaris
# changes 1.11
#  - just update license information
# changes 1.10
#  - new flag -w results in a write test on the mountpoint
#  - kernel logger logs CRITICAL check results now as CRIT
# changes 1.9
#  - new flag -i disable check of fstab (if you use automount etc.)
# changes 1.8
#  - fiexes for solaris support
#  - improved usage text
# changes 1.7
#  - new flag -A to autoread mounts from fstab and return OK if no mounts found in fstab
# changes 1.6
#  - new flag -a to autoread mounts from fstab and return UNKNOWN if no mounts found in fstab
#  - no mountpoints given returns state UNKNOWN instead of critical now
#  - parameter MTAB is used correctly on solaris now
#  - fix some minor bugs in the way variables were used
# changes 1.5
#  - returns error, if no mountpoints given
#  - change help text
# changes 1.4
#  - add support for davfs
#  - look for logger path via which command
#  - change shebang to /bin/bash
# changes 1.3
#  - add license information
# changes 1.2
#  - script doesnt hang on staled nfs mounts anymore
# changes 1.1
#  - support for nfs4
# changes 1.0
#  - support for solaris
# --------------------------------------------------------------------


# --------------------------------------------------------------------
# signal traps
# --------------------------------------------------------------------
trap 'sig_handler SIGTERM' SIGTERM
trap 'sig_handler SIGINT' SIGINT
trap 'sig_handler SIGHUP' SIGHUP
trap 'sig_handler SIGABRT' SIGABRT
trap 'sig_handler SIGQUIT' SIGQUIT
trap 'sig_handler ERR "${LINENO}" "${BASH_COMMAND}"' ERR
trap 'sig_handler EXIT' EXIT


# --------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------
PROGNAME="$(basename $0)"
PROGVERSION="3.0.0"
ERR_MESG=()
LOGGER="$(which logger) -i -p kern.warn -t"

AUTO="0"
AUTOIGNORE="0"
IGNOREFSTAB="0"
WRITETEST="0"
NOAUTOCOND="1"
NOAUTOIGNORE="0"
DFARGS=""
EXCLUDE="none"

export PATH="/bin:/usr/local/bin:/sbin:/usr/bin:/usr/sbin:/usr/sfw/bin"
LIBEXEC="/opt/nagios/libexec /usr/lib64/nagios/plugins /usr/lib/nagios/plugins /usr/lib/monitoring-plugins /usr/local/nagios/libexec /usr/local/icinga/libexec /usr/local/libexec /opt/csw/libexec/nagios-plugins /opt/plugins /usr/local/libexec/nagios/ /usr/local/ncpa/plugins"
for i in ${LIBEXEC}
do
	if [ -r "${i}/utils.sh" ]
	then
		source "${i}/utils.sh"
	fi
done

if [ -z "$STATE_OK" ]
then
	echo "nagios utils.sh not found" &>/dev/stderr
	exit 1
fi

KERNEL="$(uname -s)"
case "$KERNEL" in
	# For solaris FSF=4 MF=3 FSTAB=/etc/vfstab MTAB=/etc/mnttab gnu grep and bash required
	SunOS)
		FSF="4"
		MF="3"
		OF="6"
		NOAUTOSTR="no"
		FSTAB="/etc/vfstab"
		MTAB="/etc/mnttab"
		GREP="ggrep"
		STAT="stat"
		;;
	HP-UX)
		FSF="3"
		MF="2"
		OF="4"
		NOAUTOSTR="noauto"
		FSTAB="/etc/fstab"
		MTAB="/dev/mnttab"
		GREP="grep"
		STAT="stat"
		;;
	FreeBSD)
		FSF="3"
		MF="2"
		OF="4"
		NOAUTOSTR="noauto"
		FSTAB="/etc/fstab"
		MTAB="none"
		GREP="grep"
		STAT="stat"
		;;
	*)
		FSF="3"
		MF="2"
		OF="4"
		NOAUTOSTR="noauto"
		FSTAB="/etc/fstab"
		MTAB="/proc/mounts"
		GREP="grep"
		STAT="stat"
		;;
esac

# Time in seconds after which the check assumes that an NFS mount is staled, if
# it does not respond. (default: 3)
TIME_TILL_STALE="3"

# --------------------------------------------------------------------


# --------------------------------------------------------------------
# functions
# --------------------------------------------------------------------
log()
{
    $LOGGER ${PROGNAME} "$@"
}

usage()
{
	echo "${PROGNAME} v${PROGVERSION}"
	echo ""
    echo "Usage: ${PROGNAME} [-m FILE] \$mountpoint [\$mountpoint2 ...]"
    echo "Usage: ${PROGNAME} -h,--help"
	echo ""
    echo "Options:"
    echo " -m FILE     Use this mtab instead (default: ${MTAB})"
    echo " -f FILE     Use this fstab instead (default: ${FSTAB})"
    echo " -N NUMBER   FS Field number in fstab (default: ${FSF})"
    echo " -M NUMBER   Mount Field number in fstab (default: ${MF})"
    echo " -O NUMBER   Option Field number in fstab (default: ${OF})"
    echo " -T SECONDS  Responsetime at which an NFS is declared as staled (default: ${TIME_TILL_STALE})"
    echo " -L          Allow softlinks to be accepted instead of mount points"
    echo " -i          Ignore fstab. Do not fail just because mount is not in fstab. (default: unset)"
    echo " -a          Autoselect mounts from fstab (default: unset)"
    echo " -A          Autoselect from fstab. Return OK if no mounts found. (default: unset)"
	echo " -E PATH     Use with -a or -A to exclude a path from fstab. Use '\|' between paths for multiple. (default: unset)"
    echo " -o          When autoselecting mounts from fstab, ignore mounts having noauto flag. (default: unset)"
    echo " -w          Writetest. Touch file \$mountpoint/.mount_test_from_\$(hostname) (default: unset)"
    echo " -e ARGS     Extra arguments for df (default: unset)"
    echo " -t FS_TYPE  FS Type to check for using stat. Multiple values should be separated with commas (default: unset)"
	echo " -W	   Warning threshold of used_percent"
	echo " -C	   Critical threshold of used_percent"
	echo ""
    echo " MOUNTPOINTS list of mountpoints to check. Ignored when -a is given"
}

print_help()
{
    echo ""
    usage
    echo ""
    echo "Check if nfs/cifs/davfs/zfs/btrfs mountpoints are correctly implemented and mounted."
    echo ""
    echo "This plugin is NOT developped by the Nagios Plugin group."
    echo "Please do not e-mail them for support on this plugin, since"
    echo "they won't know what you're talking about."
    echo ""
    echo "For contact info, read the plugin itself..."
}

# Create a temporary mtab systems that don't have such a file
# Format is dev mountpoint filesystem
make_mtab()
{
	mtab="$(mktemp)"
	mount > "${mtab}"
	sed -i '' 's/ on / /' "${mtab}"
	sed -i '' 's/ (/ /' "${mtab}"
	sed -i '' 's/,.*/ /' "${mtab}"
	echo "${mtab}"
}

check_options()
{
	if [ -z "$WARN" ] && [ -n "$CRIT" ]
	then
		echo "You have defined only a critical threshold, you must define warning and critical threshold!"
		echo
		usage
		exit "${EXIT_UNKNOWN}"
	elif [ -n "$WARN" ] && [ -z "$CRIT" ]
	then
		echo "You have defined only a warning threshold, you must define warning and critical threshold!"
		echo
		usage
		exit "${EXIT_UNKNOWN}"
	elif [ -n "$WARN" ] && [ -n "$CRIT" ]
	then
		if ! is_integer "$WARN"
		then
			echo "The warning threshold: '$WARN' is not an integer!"
			echo
			usage
			exit "${EXIT_UNKNOWN}"
		fi

		if ! is_integer "$CRIT"
		then
			echo "The critical threshold: '$CRIT' is not an integer!"
			echo
			usage
			exit "${EXIT_UNKNOWN}"
		fi

		if [ "$WARN" -gt "$CRIT" ]
		then
			echo "The warning threshold: '$WARN' is greater than the critical threshold: '$CRIT'."
			echo
			usage
			exit "${EXIT_UNKNOWN}"
		fi
	fi
}

trim()
{
    local string=$@
    string="${string#"${string%%[![:space:]]*}"}"
    string="${string%"${string##*[![:space:]]}"}"
    echo -n "$string"
}

is_integer()
{
    if printf '%d' "${1}" &> /dev/null
    then
        return 0
    else
        return 1
    fi
}

add_perfdata()
{
	local MP="${1}"
	local warnstrip=
	local critstrip=
	local mpusage="$(df -h -P ${MP} | tail -n1 | awk '{print $4":"$5}')"
	local mpavail="${mpusage%%:*}"
	local mpused="${mpusage##*:}"
	local mpusedstrip="${mpused/\%/}"

	if [ -n "$WARN" ] && [ -n "$CRIT" ]
	then
		warnstrip="${WARN/\%/}"
		critstrip="${CRIT/\%/}"
		perfdata+=("'${MP}_space_avail'=$mpavail;;;; '${MP}_used_percent'=$mpused;$WARN;$CRIT;;")

		if [ "$mpusedstrip" -gt "$critstrip" ]
		then
			crit_cnt="$((crit_cnt + 1))"
			outvar+=("CRIT: Mountpoint: '${MP}' used percent is higher than critical threshold (space_avail=$mpavail, used_percent=$mpused)")
		elif [ "$mpusedstrip" -gt "$warnstrip" ]
		then
			warn_cnt="$((warn_cnt + 1))"
			outvar+=("WARN: Mountpoint: '${MP}' used percent is higher than warning threshold (space_avail=$mpavail, used_percent=$mpused)")
		else
			outvar+=("OK: Mountpoint: '${MP}' used percent is less than warning threshold (space_avail=$mpavail, used_percent=$mpused)")
		fi
	else
		perfdata+=("'${MP}_space_avail'=$mpavail;;;; '${MP}_used_percent'=$mpused;;;;")
		outvar+=("OK: Mountpoint: '${MP}' (space_avail=$mpavail, used_percent=$mpused)")
	fi
}

sig_handler()
{
	local signal="$1"
	local bash_lineno="$2"
	local bash_command="$3"
	local rc=

	case "$signal" in
		SIGTERM)
			log "Caught SIGTERM, exiting script..."
			rc="40"
			exit "${rc}"
			;;
		SIGINT)
			log "Caught SIGINT, exiting script..."
			rc="41"
			exit "${rc}"
			;;
		SIGHUP)
			log "Caught SIGHUP, exiting script..."
			rc="42"
			exit "${rc}"
			;;
		SIGABRT)
			log "Caught SIGABRT, exiting script..."
			rc="43"
			exit "${rc}"
			;;
		SIGQUIT)
			log "Caught SIGQUIT, exiting script..."
			rc="44"
			exit "${rc}"
			;;
        ERR)
            log "Caught ERR, at line number: '${bash_lineno}', command: '${bash_command}', exiting script..."
            rc="45"
            exit "${rc}"
            ;;
		EXIT)
			log "Caught EXIT, preparing for exiting..."
			cleanup
			exit
			;;
		*)
			log "Signal: '${signal}' received in function: '$FUNCNAME' but dont know what to do..."
			;;
	esac
}

cleanup()
{
	local rc=

	# Remove temporary files
	if [ -f "${TOUCHFILE}" ]
	then
		if rm "${TOUCHFILE}" &>/dev/null
		then
			log "Deleting file: '${TOUCHFILE}' was successful."
		else
			log "Deleting file: '${TOUCHFILE}' was not successful."
		fi
	fi

	if [[ "${MTAB}" =~ "/tmp" ]]
	then
		if [ -f "${MTAB}" ]
		then
			if rm "${MTAB}" &>/dev/null
			then
				log "Deleting file: '${MTAB}' was successful."
			else
				log "Deleting file: '${MTAB}' was not successful."
			fi
		fi
	fi

	if [[ "${FSTAB}" =~ "/tmp" ]]
	then
		if [ -f "${FSTAB}" ]
		then
			if rm "${FSTAB}" &>/dev/null
			then
				log "Deleting file: '${FSTAB}' was successful."
			else
				log "Deleting file: '${FSTAB}' was not successful."
			fi
		fi
	fi
}


# --------------------------------------------------------------------
# startup checks
# --------------------------------------------------------------------

if [ $# -eq 0 ]
then
    usage
    exit "${STATE_CRITICAL}"
fi

while [ "$1" != "" ]
do
    case "$1" in
		-a)
			AUTO=1
			shift
			;;
        -A)
			AUTO=1
			AUTOIGNORE=1
			shift
			;;
		-E)
			EXCLUDE=$2
			shift 2
			;;
        -o)
			NOAUTOIGNORE=1
			shift
			;;
        --help)
			print_help
			exit "${STATE_OK}"
			;;
        -h)
			print_help
			exit "${STATE_OK}"
			;;
        -m)
			MTAB=$2
			shift 2
			;;
        -f)
			FSTAB=$2
			shift 2
			;;
        -N)
			FSF=$2
			shift 2
			;;
        -M)
			MF=$2
			shift 2
			;;
        -O)
			OF=$2
			shift 2
			;;
        -T)
			TIME_TILL_STALE=$2
			shift 2
			;;
        -i)
			IGNOREFSTAB=1
			shift
			;;
        -w)
			WRITETEST=1
			shift
			;;
        -W)
			WARN=$2
			shift 2
			;;
        -C)
			CRIT=$2
			shift 2
			;;
        -L)
			LINKOK=1
			shift
			;;
        -e)
			DFARGS=$2
			shift 2
			;;
        -t)
			FSTYPE=$2
			shift 2
			;;
        /*)
			MPS="${MPS} $1"
			shift
			;;
        *)
			usage
			exit "${STATE_UNKNOWN}"
			;;
    esac
done

# check options
check_options

# set some global vars
perfdata=()
outvar=()
crit_cnt="0"
warn_cnt="0"

# ZFS file system have no fstab. Make on
if [ -x '/sbin/zfs' ]
then
	TMPTAB="$(mktemp)"
	cat "${FSTAB}" > "${TMPTAB}"
	for DS in $(zfs list -H -o name -t filesystem)
	do
		MP="$(zfs get -H mountpoint ${DS} | awk '{print $3}')"
		# mountpoint ~ "none|legacy|-"
		if [ ! -d "$MP" ]
		then
			continue
		fi
		if [ "$(zfs get -H canmount ${DS} | awk '{print $3}')" == "off" ]
		then
			continue
		fi
		case "$KERNEL" in
			SunOS)
				if [ "$(zfs get -H zoned ${DS} | awk '{print $3}')" == "on" ]
				then
					continue
				fi
				;;
			FreeBSD)
				if [ "$(zfs get -H jailed ${DS} | awk '{print $3}')" == "on" ]
				then
					continue
				fi
				;;
		esac

		RO="$(zfs get -H readonly ${DS} | awk '($3 == "on"){print "ro"}')"

		if [ -z "$RO" ]
		then
			RO="rw"
		fi

		echo -e "$DS\t$MP\tzfs\t$RO\t0\t0" >> "${TMPTAB}"
	done

	FSTAB="${TMPTAB}"
fi

if [ "${AUTO}" -eq 1 ]
then
    if [ "${NOAUTOIGNORE}" -eq 1 ]
    then
        NOAUTOCOND='!index($'${OF}',"'${NOAUTOSTR}'")'
    fi

	if [ "${EXCLUDE}" == "none" ]
	then
		MPS="$(${GREP} -v '^#' ${FSTAB} | awk '{if ('${NOAUTOCOND}'&&($'${FSF}'=="ext2" || $'${FSF}'=="ext3" || $'${FSF}'=="xfs" || $'${FSF}'=="auto" || $'${FSF}'=="ext4" || $'${FSF}'=="nfs" || $'${FSF}'=="nfs4" || $'${FSF}'=="davfs" || $'${FSF}'=="cifs" || $'${FSF}'=="fuse" || $'${FSF}'=="glusterfs" || $'${FSF}'=="ocfs2" || $'${FSF}'=="lustre" || $'${FSF}'=="ufs" || $'${FSF}'=="zfs" || $'${FSF}'=="ceph" || $'${FSF}'=="btrfs" || $'${FSF}'=="yas3fs"))print $'${MF}'}' | sed -e 's/\/$//i' | tr '\n' ' ')"
	else
		MPS="$(${GREP} -v '^#' ${FSTAB} | ${GREP} -v ${EXCLUDE} | awk '{if ('${NOAUTOCOND}'&&($'${FSF}'=="ext2" || $'${FSF}'=="ext3" || $'${FSF}'=="xfs" || $'${FSF}'=="auto" || $'${FSF}'=="ext4" || $'${FSF}'=="nfs" || $'${FSF}'=="nfs4" || $'${FSF}'=="davfs" || $'${FSF}'=="cifs" || $'${FSF}'=="fuse" || $'${FSF}'=="glusterfs" || $'${FSF}'=="ocfs2" || $'${FSF}'=="lustre" || $'${FSF}'=="ufs" || $'${FSF}'=="zfs" || $'${FSF}'=="ceph" || $'${FSF}'=="btrfs" || $'${FSF}'=="yas3fs"))print $'${MF}'}' | sed -e 's/\/$//i' | tr '\n' ' ')"
	fi
fi

if [ -z "${MPS}"  ] && [ "${AUTOIGNORE}" -eq 1 ]
then
	echo "OK: no external mounts were found in ${FSTAB}"
	exit "${STATE_OK}"
elif [ -z "${MPS}"  ]
then
    log "ERROR: no mountpoints given!"
    echo "ERROR: no mountpoints given!"
    usage
    exit "${STATE_UNKNOWN}"
fi

if [ ! -f /proc/mounts ] && [ "${MTAB}" == "/proc/mounts" ]
then
    log "CRIT: /proc wasn't mounted!"
    mount -t proc proc /proc
    ERR_MESG[${#ERR_MESG[*]}]="CRIT: mounted /proc $?"
fi

if [ "${MTAB}" == "none" ]
then
	MTAB="$(make_mtab)"
fi

if [ ! -e "${MTAB}" ]
then
    log "CRIT: ${MTAB} doesn't exist!"
    echo "CRIT: ${MTAB} doesn't exist!"
    exit "${STATE_CRITICAL}"
fi

if [ -n "${FSTYPE}" ]
then
    # split on commas
    IFS="," read -r -a fstypes <<<"${FSTYPE}"
fi

# --------------------------------------------------------------------
# now we check if the given parameters ...
#  1) ... exist in the /etc/fstab
#  2) ... are mounted
#  3) ... df -k gives no stale
#  4) ... exist on the filesystem
#  5) ... is writable (optional)
# --------------------------------------------------------------------
mpidx="0"
for MP in ${MPS}
do
    ## If its an OpenVZ Container or -a Mode is selected skip fstab check.
    ## -a Mode takes mounts from fstab, we do not have to check if they exist in fstab ;)
    if [ ! -f /proc/vz/veinfo ] && [ "${AUTO}" -ne 1 ] && [ "${IGNOREFSTAB}" -ne 1 ]
    then
        if [ -z "$( "${GREP}" -v '^#' "${FSTAB}" | awk '$'${MF}' == "'${MP}'" {print $'${MF}'}' )" ]
        then
            log "CRIT: ${MP} doesn't exist in /etc/fstab"
            ERR_MESG[${#ERR_MESG[*]}]="${MP} doesn't exist in fstab ${FSTAB}"
        fi
    fi

        ## check kernel mounts
        if [ -z "$( awk '$'${MF}' == "'${MP}'" {print $'${MF}'}' "${MTAB}" )" ]
        then
			## if a softlink is not an adequate replacement
			if [ -z "$LINKOK" ] || [ ! -L "${MP}" ]
			then
                log "CRIT: ${MP} is not mounted"
                ERR_MESG[${#ERR_MESG[*]}]="${MP} is not mounted"
            fi
        fi

        ## check if it stales
        timeout --signal=TERM --kill-after=1 "${TIME_TILL_STALE}" df -k "${DFARGS}" "${MP}" &>/dev/null
        RC="${?}"

        if [ "${RC}" == "124" ]
        then
            ERR_MESG[${#ERR_MESG[*]}]="${MP} did not respond in $TIME_TILL_STALE sec. Seems to be stale."
        else
			## if it not stales, check if it is a directory
			ISRW=0
            if [ ! -d "${MP}" ]
            then
                log "CRIT: ${MP} doesn't exist on filesystem"
                ERR_MESG[${#ERR_MESG[*]}]="${MP} doesn't exist on filesystem"
                ## if wanted, check if it is writable
			elif [ ${WRITETEST} -eq 1 ]
			then
                ISRW=1
				## in auto mode first check if it's readonly
			elif [ ${WRITETEST} -eq 1 ] && [ ${AUTO} -eq 1 ]
			then
				ISRW=1
				for OPT in $(${GREP} -w ${MP} ${FSTAB} | awk '{print $4}'| sed -e 's/,/ /g')
				do
					if [ "$OPT" == 'ro' ]
					then
						ISRW=0
                        log "CRIT: ${TOUCHFILE} is not mounted as writable."
                        ERR_MESG[${#ERR_MESG[*]}]="Could not write in ${MP} filesystem was mounted RO."
					fi
				done
			fi
			if [ ${ISRW} -eq 1 ]
			then
				TOUCHFILE="${MP}/.mount_test_from_$(hostname)_$(date +%Y-%m-%d--%H-%M-%S).$RANDOM.$$"
				timeout --signal=TERM --kill-after=1 "${TIME_TILL_STALE}" touch "${TOUCHFILE}" &>/dev/null
				RC="${?}"

        		if [ "${RC}" == "124" ]
        		then
					log "CRIT: ${TOUCHFILE} is not writable."
					ERR_MESG[${#ERR_MESG[*]}]="Could not write in ${MP} in $TIME_TILL_STALE sec. Seems to be stale."
				else
					if [ ! -f "${TOUCHFILE}" ]
					then
						log "CRIT: ${TOUCHFILE} is not writable."
						ERR_MESG[${#ERR_MESG[*]}]="Could not write in ${MP}."
					else
						rm "${TOUCHFILE}" &>/dev/null
					fi
				fi
            fi
        fi

		add_perfdata "${MP}"

        # Check for FS type using stat
        efstype="${fstypes[$mpidx]}"
        mpidx="$(( mpidx + 1 ))"

        if [ -z "${efstype}" ]
        then
            continue
        fi

        if ! rfstype="$(${STAT} -f --printf='%T' "${MP}")"
        then
            log "CRIT: Fail to fetch FS type for ${MP}"
            ERR_MESG[${#ERR_MESG[*]}]="Fail to fetch FS type for ${MP}"
            continue
        fi

        if [ "${rfstype}" != "${efstype}" ]
        then
            log "CRIT: Bad FS type for ${MP}"
            ERR_MESG[${#ERR_MESG[*]}]="Bad FS type for ${MP}. Got '${rfstype}' while '${efstype}' was expected"
            continue
        fi
	done

	if [ ${#ERR_MESG[*]} -ne 0 ]
	then
        echo -n "CRITICAL: "
        for element in "${ERR_MESG[@]}"
        do
            echo -n "${element} ; "
        done
        echo
        exit "${STATE_CRITICAL}"
	else
		MPS="$(trim ${MPS[*]})"
		MPS="${MPS// /, }"

		if [ "$crit_cnt" -gt 0 ]
		then
			echo "CRIT: All mounts (${MPS[*]}) were found, but critical threshold exceeded."
			STATE="$STATE_CRITICAL"
		elif [ "$warn_cnt" -gt 0 ]
		then
			echo "WARN: All mounts (${MPS[*]}) were found, but warning threshold exceeded."
			STATE="$STATE_WARNING"
		else
			if [ -n "$WARN" ] && [ -n "$CRIT" ]
			then
				echo "OK: All mounts (${MPS[*]}) were found, no thresholds exceeded."
				STATE="$STATE_OK"
			else
				echo "OK: All mounts (${MPS[*]}) were found, no thresholds defined."
				STATE="$STATE_OK"
			fi
		fi

		for item in "${outvar[@]}"
		do
			echo "${item}"
		done

		echo "| ${perfdata[*]}"
		exit "${STATE}"
	fi
