#!/bin/bash
# hpc-testing
# Copyright (C) 2025 SUSE LLC
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

#########################
#
# Usefull wrappers
#
#########################
fatal_error()
{
    echo -e "ERROR:" "$@" >&2
    exit 1
}

ip_addr_show_to_ip()
{
    grep inet /dev/stdin  | grep -v inet6 | sed -e 's/.*inet \([0-9.]*\)\/\?.*$/\1/'
}
ip_addr_show_to_ipv6()
{
    grep inet6 /dev/stdin  | sed -e 's/.*inet6 \([0-9a-f:]*\)\/\?.*$/\1/'
}
ip_addr_show_to_mac_ipv6()
{
    # Scrub the first 4 bytes and the 6 NULL bytes after fe80
    # Then remove and readd the proper columns
    grep link/infiniband | awk '{ print $2}' | \
        sed -e 's/\([0-9a-f][0-9a-f]:\)\{4\}fe:80:\([0-9a-f][0-9a-f]:\)\{6\}/fe:80:/'  -e 's/://g'\
            -e 's/\([0-9a-f]\{4\}\)/\1:/g' -e 's/:/::'/ -e 's/:$//'
}

ip_addr_show_to_dev()
{
    local ip=$1
    grep inet /dev/stdin  | grep -v inet6 | grep $ip | awk '{ print $NF}'
}

tp_check_local()
{
    local host=$1
    local varname
    local ip

    varname=IS_LOCAL_$(echo $host | tr '.' '_')
    # Check if the IP is local and store the value
    if [ "${!varname}" == "" ]; then
	export ${varname}=1
	IP_LIST=$(ip addr show | grep inet  | grep -v inet6 | sed -e 's/.*inet \([0-9.]*\)\/\?.*$/\1/')
	for ip in $IP_LIST; do
	    if [ "$ip" == "$host" ]; then
		export ${varname}=0
		break
	    fi
	done
    fi
    return ${!varname}
}

SSH_COMMAND="timeout 300 ssh -o ConnectTimeout=5 -o BatchMode=yes"

tp()
{
    local ip=$1
    shift

    if tp_check_local $ip; then
	echo "$@"
	set -e
	(
	    cd $HOME;
	    set -x
	    eval "$@"
	)
	set +e
    else
        echo "ssh $ip $*"
        set -e
        cat <<EOF | ${SSH_COMMAND} $ip "bash -"
shopt -s huponexit
set -x
$@
EOF
        set +e
    fi
}

tp_fun()
{
    local ip=$1
    shift
    local fn=$1
    shift
    tp $ip "$(declare -f $fn); $fn" "$@"
}

tpq()
{
    local ip=$1
    local ret=0
    shift

    if tp_check_local $ip; then
	set -e
	(
	    cd $HOME;
	    eval "$@"
	)
	ret=$?
	set +e
    else
	set -e
        ${SSH_COMMAND} "$ip" "$@"
	ret=$?
	set +e
    fi
    return $ret
}

tpq_fun()
{
    local ip=$1
    shift
    local fn=$1
    shift
    tpq $ip "$(declare -f $fn); $fn" "$@"
}

load_helpers()
{
    local topdir=$1
    local test_type
    local helper

    source "${topdir}/helpers/julog.sh"
    shift 1

    while [ "$#" -gt 0 ]; do
        test_type=$1
        for helper in $(ls "${topdir}/helpers/${test_type}/"[0-9][0-9]* | grep -E -v '.*~$'); do
	    source ${helper}
        done
        shift
    done
}

run_phase(){
    local phase=$1
    local func=$2
    shift 2
    juLogSetClassName "phase.$phase.$(echo $* | tr 'A-Z' 'a-z' | tr ' '  '.')"
    if [ $END_PHASE -lt $phase ]; then
	# We reach passed the last phase
	# exit now
	exit 0
    fi
    if [ $START_PHASE -gt $phase -o $END_PHASE -lt $phase ]; then
	echo "Skipping phase $phase"
	return 0
    else
	echo "*******************************"
	echo "*** Phase $phase: $*"
	echo "*******************************"
	eval $func
	status=$?
	echo "*******************************"
	echo "*** End of phase $phase: $* Status=$status"
	echo "*******************************"
    fi
}

get_suse_version(){
    local host=$1
    local varname

    varname=SUSE_VERSION_$(echo $host | tr '.' '_')
    if [ "${!varname}" == "" ]; then
	export ${varname}=$(tpq $host 'source /etc/os-release; echo $VERSION_ID')
    fi
    echo ${!varname}
    return 0
}

#####################
# Phase parsing stuff
#####################
DEFAULT_START_PHASE=0
DEFAULT_END_PHASE=999

export START_PHASE=${START_PHASE:-$DEFAULT_START_PHASE}
export END_PHASE=${END_PHASE:-$DEFAULT_END_PHASE}
export IN_VM=0
export HOST1=
export HOST2=

common_usage(){
    echo "  -h, --help                     Display usage"
    echo "  -s, --start-phase              Phase to start from (default is $DEFAULT_START_PHASE)"
    echo "  -e, --end-phase                Phase to stop at (default is $DEFAULT_END_PHASE)"
    echo "  -p, --phase <#phase>           Launch only this phase"
    echo "  -v, --verbose                  Display test logs in console."
    echo "      --in-vm                    Test is being run in a virtual machine"
    echo "  -S, --suite <name>             Set JUnit testsuite name"
    echo "  -M, --mpi <mpi>[,<mpi>...]     Comma separated list of MPI flavours to test"

}

common_parse(){
    case $1 in
	-s|--start-phase)
	    START_PHASE=$2
	    return 2
	    ;;
	-e|--end-phase)
	    END_PHASE=$2
	    return 2
	    ;;
	-p|--phase)
	    START_PHASE=$2
	    END_PHASE=$2
	    return 2
	    ;;
	-v|--verbose)
	    export VERBOSE=1
	    return 1
	    ;;
	--in-vm)
	    IN_VM=1
	    return 1
	    ;;
        -S|--suite)
            juSUITE=$2
            return 2
            ;;
	-M|--mpi)
	    MPI_FLAVOURS=$2
	    return 2
	    ;;
	--help|-h)
	    usage $0
	    exit 1
	    ;;
	[0-9]*.[0-9]*.[0-9]*.[0-9]*)
	    if [ "$HOST1" == "" ]; then
		HOST1=$1
		return 1
	    elif [ "$HOST2" == "" ]; then
		HOST2=$1
		return 1
	    else
		fatal_error "Too many host ip provided '$2'"
	    fi
	    ;;
	*)
	    return 0
	    ;;
    esac
}

common_check(){
    if [ "$HOST1" == "" -o "$HOST2" == "" ]; then
	usage $0
	fatal_error "Missing host names"
    fi
}
