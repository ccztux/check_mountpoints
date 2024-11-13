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
#  - fix bad bug in mtab check
# changes 1.14
#  - better support for HP-UX, Icinga
#  - cleanUp writecheck file after check
# changes 1.13
#  - add support for glusterfs
# changes 1.12
#  - add libexec path for OpenCSW-installed nagios in Solaris
# changes 1.11
#  - just update license information
# changes 1.10
#  - new flag -w results in a write test on the mountpoint
#  - kernel logger_cmd logs CRITICAL check results now as crit
# changes 1.9
#  - new flag -i disable check of fstab (if you use automount etc.)
# changes 1.8
#  - fiexes for solaris support
#  - improved printUsage text
# changes 1.7
#  - new flag -A to autoread mounts from fstab and return OK if no mounts found in fstab
# changes 1.6
#  - new flag -a to autoread mounts from fstab and return UNKNOWN if no mounts found in fstab
#  - no mountpoints given returns state UNKNOWN instead of critical now
#  - parameter mtab is used correctly on solaris now
#  - fix some minor bugs in the way variables were used
# changes 1.5
#  - returns error, if no mountpoints given
#  - change help text
# changes 1.4
#  - add support for davfs
#  - look for logger_cmd path via which command
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
trap 'signalHandler SIGTERM' SIGTERM
trap 'signalHandler SIGINT' SIGINT
trap 'signalHandler SIGHUP' SIGHUP
trap 'signalHandler EXIT' EXIT




# --------------------------------------------------------------------
# functions
# --------------------------------------------------------------------
logHandler()
{
    ${logger_cmd} "${progname}" "$@"
}

printUsage()
{
	echo "${progname} v${progversion}"
	echo ""
    echo "Usage: ${progname} [-m FILE] \${mountpoint} [\${mountpoint2} ...]"
    echo "Usage: ${progname} -h,--help"
	echo ""
    echo "Options:"
    echo " -m FILE     Use this mtab instead (default: ${mtab})"
    echo " -f FILE     Use this fstab instead (default: ${fstab})"
    echo " -N NUMBER   FS Field number in fstab (default: ${fsf})"
    echo " -M NUMBER   Mount Field number in fstab (default: ${mf})"
    echo " -O NUMBER   Option Field number in fstab (default: ${of})"
    echo " -T SECONDS  Responsetime at which an NFS is declared as staled (default: ${time_till_stale})"
    echo " -L          Allow softlinks to be accepted instead of mount points"
    echo " -i          Ignore fstab. Do not fail just because mount is not in fstab. (default: unset)"
    echo " -a          Autoselect mounts from fstab (default: unset)"
    echo " -A          Autoselect from fstab. Return OK if no mounts found. (default: unset)"
	echo " -E PATH     Use with -a or -A to exclude a path from fstab. Use '\|' between paths for multiple. (default: unset)"
    echo " -o          When autoselecting mounts from fstab, ignore mounts having noauto flag. (default: unset)"
    echo " -w          Writetest. Touch file \${mountpoint}/.mount_test_from_\${HOSTNAME} (default: unset)"
    echo " -e ARGS     Extra arguments for df (default: unset)"
    echo " -t FS_TYPE  FS Type to check for using stat. Multiple values should be separated with commas (default: unset)"
	echo " -W	   Warning threshold of used_percent"
	echo " -C	   Critical threshold of used_percent"
	echo ""
    echo " MOUNTPOINTS list of mountpoints to check. Ignored when -a is given"
}

printHelp()
{
    echo ""
    printUsage
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
makeMtab()
{
	mtab="$(mktemp)"
	mount > "${mtab}"
	sed -i '' 's/ on / /' "${mtab}"
	sed -i '' 's/ (/ /' "${mtab}"
	sed -i '' 's/,.*/ /' "${mtab}"
	echo "${mtab}"
}

checkOptions()
{
	if [ -z "${warn}" ] && [ -n "${crit}" ]
	then
		echo "You have defined only a critical threshold, you must define warning and critical threshold!"
		echo
		printUsage
		exit "${EXIT_UNKNOWN}"
	elif [ -n "${warn}" ] && [ -z "${crit}" ]
	then
		echo "You have defined only a warning threshold, you must define warning and critical threshold!"
		echo
		printUsage
		exit "${EXIT_UNKNOWN}"
	elif [ -n "${warn}" ] && [ -n "${crit}" ]
	then
		if ! isInteger "${warn}"
		then
			echo "The warning threshold: '${warn}' is not an integer!"
			echo
			printUsage
			exit "${EXIT_UNKNOWN}"
		fi

		if ! isInteger "${crit}"
		then
			echo "The critical threshold: '${crit}' is not an integer!"
			echo
			printUsage
			exit "${EXIT_UNKNOWN}"
		fi

		if [ "${warn}" -gt "${crit}" ]
		then
			echo "The warning threshold: '${warn}' is greater than the critical threshold: '${crit}'."
			echo
			printUsage
			exit "${EXIT_UNKNOWN}"
		fi
	fi
}

trim()
{
    local string="${1}"
    string="${string#"${string%%[![:space:]]*}"}"
    string="${string%"${string##*[![:space:]]}"}"
    echo -n "${string}"
}

isInteger()
{
    if printf '%d' "${1}" &> /dev/null
    then
        return 0
    else
        return 1
    fi
}

addPerfdata()
{
	local mp="${1}"
	local warnstrip=
	local critstrip=
	local mpusage=
	mpusage="$(timeout --signal=TERM --kill-after=1 "${time_till_stale}" df -h -P "${mp}" | tail -n1 | awk '{print $4":"$5}')"
	local mpavail="${mpusage%%:*}"
	local mpused="${mpusage##*:}"
	local mpusedstrip="${mpused/\%/}"

	if [ -n "${warn}" ] && [ -n "${crit}" ]
	then
		warnstrip="${warn/\%/}"
		critstrip="${crit/\%/}"
		perfdata+=("'${mp}_space_avail'=${mpavail};;;; '${mp}_used_percent'=${mpused};${warn};${crit};;")

		if [ "${mpusedstrip}" -gt "${critstrip}" ]
		then
			crit_cnt="$(( crit_cnt + 1 ))"
			outvar+=("CRITICAL: Mountpoint: '${mp}' used percent is higher than critical threshold (space_avail=${mpavail}, used_percent=${mpused})")
		elif [ "${mpusedstrip}" -gt "${warnstrip}" ]
		then
			warn_cnt="$(( warn_cnt + 1 ))"
			outvar+=("WARNING: Mountpoint: '${mp}' used percent is higher than warning threshold (space_avail=${mpavail}, used_percent=${mpused})")
		else
			outvar+=("OK: Mountpoint: '${mp}' used percent is less than warning threshold (space_avail=${mpavail}, used_percent=${mpused})")
		fi
	else
		perfdata+=("'${mp}_space_avail'=${mpavail};;;; '${mp}_used_percent'=${mpused};;;;")
		outvar+=("OK: Mountpoint: '${mp}' (space_avail=${mpavail}, used_percent=${mpused})")
	fi
}

signalHandler()
{
	local signal="$1"

	case "${signal}" in
		SIGTERM)
			logHandler "Caught SIGTERM, exiting script..."
            exit
			;;
		SIGINT)
			logHandler "Caught SIGINT, exiting script..."
            exit
			;;
		SIGHUP)
			logHandler "Caught SIGHUP, exiting script..."
            exit
			;;
		EXIT)
			logHandler "Caught EXIT, preparing for exiting..."
			cleanUp

			if [ ${#err_mesg[*]} != 0 ]
			then
			    echo -n "CRITICAL: "
			    for element in "${err_mesg[@]}"
			    do
			        echo -n "${element} , "
			    done
			    echo
			    exit "${STATE_CRITICAL}"
            fi

            if [ "${bypass_exit_routine}" != "1" ]
            then
				mps="$(trim ${mps[*]})"
				mps="${mps// /, }"

				if [ "${crit_cnt}" -gt 0 ]
				then
					echo "CRITICAL: All mounts (${mps[*]}) were found, but critical threshold exceeded."
					state="$STATE_CRITICAL"
				elif [ "${warn_cnt}" -gt 0 ]
				then
					echo "WARNING: All mounts (${mps[*]}) were found, but warning threshold exceeded."
					state="$STATE_WARNING"
				else
					if [ -n "${warn}" ] && [ -n "${crit}" ]
					then
						echo "OK: All mounts (${mps[*]}) were found, no thresholds exceeded."
						state="$STATE_OK"
					else
						echo "OK: All mounts (${mps[*]}) were found, no thresholds defined."
						state="$STATE_OK"
					fi
				fi

				for item in "${outvar[@]}"
				do
					echo "${item}"
				done

				if [ "${#perfdata[@]}" != "0" ]
				then
					echo "| ${perfdata[*]}"
                fi

				exit "${state}"
			fi

			exit
			;;
		*)
			logHandler "Signal: '${signal}' received in function: '${FUNCNAME[0]}' but dont know what to do..."
			;;
	esac
}

setConfig()
{
	# --------------------------------------------------------------------
	# configuration
	# --------------------------------------------------------------------

    # set some global vars
    bypass_exit_routine="1"
    perfdata=()
    outvar=()
    crit_cnt="0"
    warn_cnt="0"

	progname="$(basename "$0")"
	progversion="3.0.0"
	err_mesg=()
	logger_cmd="$(which logger) -i -p kern.warn -t"

	auto="0"
	autoignore="0"
	ignorefstab="0"
	writetest="0"
	noautocond="1"
	noautoignore="0"
	dfargs=""
	exclude="none"

	export PATH="/bin:/usr/local/bin:/sbin:/usr/bin:/usr/sbin:/usr/sfw/bin"
	libexec="/opt/nagios/libexec /usr/lib64/nagios/plugins /usr/lib/nagios/plugins /usr/lib/monitoring-plugins /usr/local/nagios/libexec /usr/local/icinga/libexec /usr/local/libexec /opt/csw/libexec/nagios-plugins /opt/plugins /usr/local/libexec/nagios/ /usr/local/ncpa/plugins"
	for i in ${libexec}
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

	kernel="$(uname -s)"
	case "${kernel}" in
		# For solaris fsf=4 mf=3 fstab=/etc/vfstab mtab=/etc/mnttab gnu grep and bash required
		SunOS)
			fsf="4"
			mf="3"
			of="6"
			noautostr="no"
			fstab="/etc/vfstab"
			mtab="/etc/mnttab"
			grep_bin="ggrep"
			stat="stat"
			;;
		HP-UX)
			fsf="3"
			mf="2"
			of="4"
			noautostr="noauto"
			fstab="/etc/fstab"
			mtab="/dev/mnttab"
			grep_bin="grep"
			stat="stat"
			;;
		FreeBSD)
			fsf="3"
			mf="2"
			of="4"
			noautostr="noauto"
			fstab="/etc/fstab"
			mtab="none"
			grep_bin="grep"
			stat="stat"
			;;
		*)
			fsf="3"
			mf="2"
			of="4"
			noautostr="noauto"
			fstab="/etc/fstab"
			mtab="/proc/mounts"
			grep_bin="grep"
			stat="stat"
			;;
	esac

	# Time in seconds after which the check assumes that an NFS mount is staled, if
	# it does not respond. (default: 3)
	time_till_stale="3"

	# --------------------------------------------------------------------
}

cleanUp()
{
	local rc=

	# Remove temporary files
	if [ -f "${touchfile}" ]
	then
		if rm "${touchfile}" &>/dev/null
		then
			logHandler "Deleting file: '${touchfile}' was successful."
		else
			logHandler "Deleting file: '${touchfile}' was not successful."
		fi
	fi

	if [[ "${mtab}" =~ "/tmp" ]]
	then
		if [ -f "${mtab}" ]
		then
			if rm "${mtab}" &>/dev/null
			then
				logHandler "Deleting file: '${mtab}' was successful."
			else
				logHandler "Deleting file: '${mtab}' was not successful."
			fi
		fi
	fi

	if [[ "${fstab}" =~ "/tmp" ]]
	then
		if [ -f "${fstab}" ]
		then
			if rm "${fstab}" &>/dev/null
			then
				logHandler "Deleting file: '${fstab}' was successful."
			else
				logHandler "Deleting file: '${fstab}' was not successful."
			fi
		fi
	fi
}



# set configuration
setConfig


# --------------------------------------------------------------------
# startup checks
# --------------------------------------------------------------------

if [ "${#}" == "0" ]
then
    printUsage
    exit "${STATE_CRITICAL}"
fi

while [ "$1" != "" ]
do
    case "$1" in
		-a)
			auto="1"
			shift
			;;
        -A)
			auto="1"
			autoignore="1"
			shift
			;;
		-E)
			exclude="${2}"
			shift 2
			;;
        -o)
			noautoignore="1"
			shift
			;;
        --help)
			printHelp
			exit "${STATE_OK}"
			;;
        -h)
			printHelp
			exit "${STATE_OK}"
			;;
        -m)
			mtab="${2}"
			shift 2
			;;
        -f)
			fstab="${2}"
			shift 2
			;;
        -N)
			fsf="${2}"
			shift 2
			;;
        -M)
			mf="${2}"
			shift 2
			;;
        -O)
			of="${2}"
			shift 2
			;;
        -T)
			time_till_stale="${2}"
			shift 2
			;;
        -i)
			ignorefstab="1"
			shift
			;;
        -w)
			writetest="1"
			shift
			;;
        -W)
			warn="${2}"
			shift 2
			;;
        -C)
			crit="${2}"
			shift 2
			;;
        -L)
			linkok="1"
			shift
			;;
        -e)
			dfargs="${2}"
			shift 2
			;;
        -t)
			fstype="${2}"
			shift 2
			;;
        /*)
			mps+="${1} "
			shift
			;;
        *)
			printUsage
			exit "${STATE_UNKNOWN}"
			;;
    esac
done

# check options
checkOptions
bypass_exit_routine="0"


# ZFS file system have no fstab. Make one
if [ -x "/sbin/zfs" ]
then
	tmptab="$(mktemp)"
	cat "${fstab}" > "${tmptab}"
	for ds in $(zfs list -H -o name -t filesystem)
	do
		mp="$(zfs get -H mountpoint ${ds} | awk '{print $3}')"
		# mountpoint ~ "none|legacy|-"
		if [ ! -d "${mp}" ]
		then
			continue
		fi
		if [ "$(zfs get -H canmount ${ds} | awk '{print $3}')" == "off" ]
		then
			continue
		fi
		case "${kernel}" in
			SunOS)
				if [ "$(zfs get -H zoned ${ds} | awk '{print $3}')" == "on" ]
				then
					continue
				fi
				;;
			FreeBSD)
				if [ "$(zfs get -H jailed ${ds} | awk '{print $3}')" == "on" ]
				then
					continue
				fi
				;;
		esac

		ro="$(zfs get -H readonly ${ds} | awk '($3 == "on"){print "ro"}')"

		if [ -z "${ro}" ]
		then
			ro="rw"
		fi

		echo -e "${ds}\t${mp}\tzfs\t${ro}\t0\t0" >> "${tmptab}"
	done

	fstab="${tmptab}"
fi

if [ "${auto}" == "1" ]
then
    if [ "${noautoignore}" == "1" ]
    then
        noautocond='!index($'${of}',"'${noautostr}'")'
    fi

	if [ "${exclude}" == "none" ]
	then
		mps="$(${grep_bin} -v '^#' ${fstab} | awk '{if ('${noautocond}'&&($'${fsf}'=="ext2" || $'${fsf}'=="ext3" || $'${fsf}'=="xfs" || $'${fsf}'=="auto" || $'${fsf}'=="ext4" || $'${fsf}'=="nfs" || $'${fsf}'=="nfs4" || $'${fsf}'=="davfs" || $'${fsf}'=="cifs" || $'${fsf}'=="fuse" || $'${fsf}'=="glusterfs" || $'${fsf}'=="ocfs2" || $'${fsf}'=="lustre" || $'${fsf}'=="ufs" || $'${fsf}'=="zfs" || $'${fsf}'=="ceph" || $'${fsf}'=="btrfs" || $'${fsf}'=="yas3fs"))print $'${mf}'}' | sed -e 's/\/$//i' | tr '\n' ' ')"
	else
		mps="$(${grep_bin} -v '^#' ${fstab} | ${grep_bin} -v ${exclude} | awk '{if ('${noautocond}'&&($'${fsf}'=="ext2" || $'${fsf}'=="ext3" || $'${fsf}'=="xfs" || $'${fsf}'=="auto" || $'${fsf}'=="ext4" || $'${fsf}'=="nfs" || $'${fsf}'=="nfs4" || $'${fsf}'=="davfs" || $'${fsf}'=="cifs" || $'${fsf}'=="fuse" || $'${fsf}'=="glusterfs" || $'${fsf}'=="ocfs2" || $'${fsf}'=="lustre" || $'${fsf}'=="ufs" || $'${fsf}'=="zfs" || $'${fsf}'=="ceph" || $'${fsf}'=="btrfs" || $'${fsf}'=="yas3fs"))print $'${mf}'}' | sed -e 's/\/$//i' | tr '\n' ' ')"
	fi
fi

if [ -z "${mps}"  ] && [ "${autoignore}" == "1" ]
then
	echo "OK: no external mounts were found in ${fstab}"
	exit "${STATE_OK}"
elif [ -z "${mps}"  ]
then
    logHandler "ERROR: no mountpoints given!"
    echo "ERROR: no mountpoints given!"
    printUsage
    exit "${STATE_UNKNOWN}"
fi

if [ ! -f /proc/mounts ] && [ "${mtab}" == /proc/mounts ]
then
    logHandler "CRITICAL: /proc wasn't mounted!"
    mount -t proc proc /proc
    err_mesg+=("CRITICAL: mounted /proc $?")
fi

if [ "${mtab}" == "none" ]
then
	mtab="$(makeMtab)"
fi

if [ ! -e "${mtab}" ]
then
    logHandler "CRITICAL: ${mtab} doesn't exist!"
    echo "CRITICAL: ${mtab} doesn't exist!"
    exit "${STATE_CRITICAL}"
fi

if [ -n "${fstype}" ]
then
    # split on commas
    IFS="," read -r -a fstypes <<<"${fstype}"
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
for mp in ${mps}
do
    ## If its an OpenVZ Container or -a Mode is selected skip fstab check.
    ## -a Mode takes mounts from fstab, we do not have to check if they exist in fstab ;)
    if [ ! -f /proc/vz/veinfo ] && [ "${auto}" != 1 ] && [ "${ignorefstab}" != 1 ]
    then
        if [ -z "$( "${grep_bin}" -v '^#' "${fstab}" | awk '$'${mf}' == "'${mp}'" {print $'${mf}'}' )" ]
        then
            logHandler "CRITICAL: ${mp} doesn't exist in /etc/fstab"
            err_mesg+=("${mp} doesn't exist in fstab ${fstab}")
        fi
    fi

	## check kernel mounts
    if [ -z "$( awk '$'${mf}' == "'${mp}'" {print $'${mf}'}' "${mtab}" )" ]
    then
		## if a softlink is not an adequate replacement
		if [ -z "${linkok}" ] || [ ! -L "${mp}" ]
		then
            logHandler "CRITICAL: ${mp} is not mounted"
            err_mesg+=("${mp} is not mounted")
        fi
    fi

    ## check if it stales
    timeout --signal=TERM --kill-after=1 "${time_till_stale}" df -k "${dfargs}" "${mp}" &>/dev/null
    rc="${?}"

    if [ "${rc}" == "124" ]
    then
        err_mesg+=("${mp} did not respond in ${time_till_stale} sec. Seems to be stale.")
    else
		## if it not stales, check if it is a directory
		is_rw="0"
        if [ ! -d "${mp}" ]
        then
            logHandler "CRITICAL: ${mp} doesn't exist on filesystem"
            err_mesg+=("${mp} doesn't exist on filesystem")
            ## if wanted, check if it is writable
		elif [ "${writetest}" == "1" ]
		then
            is_rw="1"
			## in auto mode first check if it's readonly
		elif [ "${writetest}" == "1" ] && [ "${auto}" == "1" ]
		then
			is_rw="1"
			for opt in $(${grep_bin} -w "${mp}" "${fstab}" | awk '{print $4}'| sed -e 's/,/ /g')
			do
				if [ "${opt}" == "ro" ]
				then
					is_rw="0"
                    logHandler "CRITICAL: ${touchfile} is not mounted as writable."
                    err_mesg+=("Could not write in ${mp} filesystem was mounted RO.")
				fi
			done
		fi
		if [ "${is_rw}" == "1" ]
		then
			touchfile="${mp}/.mount_test_from_${HOSTNAME}_$(date +%Y-%m-%d--%H-%M-%S).${RANDOM}.${$}"
			timeout --signal=TERM --kill-after=1 "${time_till_stale}" touch "${touchfile}" &>/dev/null
			rc="${?}"

    		if [ "${rc}" == "124" ]
    		then
				logHandler "CRITICAL: ${touchfile} is not writable."
				err_mesg+=("Could not write in ${mp} in ${time_till_stale} sec. Seems to be stale.")
			else
				if [ ! -f "${touchfile}" ]
				then
					logHandler "CRITICAL: ${touchfile} is not writable."
					err_mesg+=("Could not write in ${mp}.")
				else
					rm "${touchfile}" &>/dev/null
				fi
			fi
        fi
    fi

	addPerfdata "${mp}"

    # Check for FS type using stat
    efstype="${fstypes[${mpidx}]}"
    mpidx="$(( mpidx + 1 ))"

    if [ -z "${efstype}" ]
    then
        continue
    fi

    if ! rfstype="$(${stat} -f --printf='%T' "${mp}")"
    then
        logHandler "CRITICAL: Fail to fetch FS type for ${mp}"
        err_mesg+=("Fail to fetch FS type for ${mp}")
        continue
    fi

    if [ "${rfstype}" != "${efstype}" ]
    then
        logHandler "CRITICAL: Bad FS type for ${mp}"
        err_mesg+=("Bad FS type for ${mp}. Got '${rfstype}' while '${efstype}' was expected")
        continue
    fi
done

exit
