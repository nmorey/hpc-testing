#!/bin/bash
# hpc-testing
# Copyright (C) 2018 SUSE LLC
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

DEFAULT_IPPORT1=eth0
DEFAULT_IPPORT2=eth0

export IPPORT1=""
export IPPORT2=""
export DO_MAD=0

source $(dirname $0)/helpers/common.sh
load_helpers $(dirname $0) "common"
load_helpers $(dirname $0) "rxe"

usage(){
    echo "Usage: ${0} [options] <host1> <host2>"
    echo "Options:"
    common_usage
    echo "      --eth1 <ifname>            Name of the IP interface to setup/use for RXE on host1 (default is $DEFAULT_IPPORT1)"
    echo "      --eth2 <ifname>            Name of the IP interface to setup/use for RXE on host2 (default is $DEFAULT_IPPORT2)"
    echo "  -M, --mpi <mpi>[,<mpi>...]     Comma separated list of MPI flavours to test"
}

while [ $# -ne 0 ]; do
    common_parse $1 $2
    ret=$?
    if [ $ret -ne 0 ]; then
	shift $ret
	continue
    fi

    case $1 in
	--eth1)
	    IPPORT1=$2
	    shift
	    ;;
	--eth2)
	    IPPORT2=$2
	    shift
	    ;;
	-M|--mpi)
	    MPI_FLAVOURS=$2
	    shift
	    ;;
	*)
	    fatal_error "Unknow argument $1"
	    ;;
    esac
    shift
done
common_check

if [ "$IPPORT1" == "" ]; then
    export IPPORT1=$(tpq $HOST1 "ip addr" | ip_addr_show_to_dev $HOST1)
fi
if [ "$IPPORT1" == "" ]; then
    fatal_error "No ethernet device specified or found for $HOST1"
fi

if [ "$IPPORT2" == "" ]; then
    export IPPORT2=$(tpq $HOST2 "ip addr" | ip_addr_show_to_dev $HOST2)
fi
if [ "$IPPORT2" == "" ]; then
    fatal_error "No ethernet device specified or found for $HOST2"
fi

juLogSetProperty host1.name $HOST1
juLogSetProperty host2.name $HOST2

#########################
#
# Phase 0: State cleanup
# - Install required packages
# - Reset everything needed to mimic an after-reboot run
#
#########################
phase_0(){
    juLog_fatal -name=h1_setup_requirements "setup_requirements $HOST1"
    juLog_fatal -name=h2_setup_requirements "setup_requirements $HOST2"

    # Remove all RDMA ports first just to be sure
    juLog_fatal -name=h1_remove_rdma_ports "disable_unused_rdma_ports $HOST1"
    juLog_fatal -name=h2_remove_rdma_ports "disable_unused_rdma_ports $HOST2"

    juLog -name=h1_firewall_down "firewall_down $HOST1"
    juLog -name=h2_firewall_down "firewall_down $HOST2"

}
run_phase 0 phase_0 "State Cleanup"

set_properties $HOST1
set_properties $HOST2
juLogSetProperty $HOST1.rxe_eth $IPPORT1
juLogSetProperty $HOST2.rxe_eth $IPPORT2

#########################
#
# Phase 1: Fabric init
# - SSH known key setup to as some tests will fail if
#   hosts do not know each other
# - Device status check
#
#########################
# Do not wrap these as they export needed variables
get_srdma_port $HOST1 1 rxe
get_srdma_port $HOST2 2 rxe

phase_1(){
    juLog_fatal -name=h1_setup_ssh_keys "setup_ssh $HOST1 $IP2"
    juLog_fatal -name=h2_setup_ssh_keys "setup_ssh $HOST2 $IP1"

    juLog_fatal -name=h1_ibvinfo tp $HOST1 ibv_devinfo
    juLog_fatal -name=h2_ibvinfo tp $HOST2 ibv_devinfo

}
run_phase 1 phase_1 "Fabric init"

#########################
#
# Skipping these not applicable phases
# Phase 2: IPoIB
# Phase 3: SM Failover
# Phase 4: SRP
#
#########################
#########################
#
# Phase 5: NFSoRDMA
#
#########################
phase_5(){
    juLog -name=nfs_over_rdma test_nfs $HOST1 $IP1 $HOST2
}
run_phase 5 phase_5 "NFSoRDMA"

#########################
#
# Not applicable
# Phase 6: DAPL
#
#########################

#########################
#
# Phase 7: RDMA/Verbs
#
#########################
phase_7(){
    for mode in rc uc ud srq; do
	export IBV_EXTRA_OPTS=""
	if [ "$mode" == "ud" ]; then
	    IBV_EXTRA_OPTS="-s 1024"
	fi
	juLog -name=${mode}_pingpong "(
	  	  test_ibv_pingpong ibv_${mode}_pingpong $HOST1 $HCA1 $IBPORT1 $HOST2 $HCA2 $IBPORT2 &&
	  	  test_ibv_pingpong ibv_${mode}_pingpong $HOST2 $HCA2 $IBPORT2 $HOST1 $HCA1 $IBPORT1
        )"
    done
}
run_phase 7 phase_7 "RDMA/Verbs"

#########################
#
# Phase 8: MPI
#
#########################
phase_8(){
    FLAVOURS=$(mpi_get_flavors $HOST1 $MPI_FLAVOURS)
    # Right now, it seems only OpenMPI[25] works fine with RXE
    FLAVOURS=$(mpi_filter_flavour $FLAVOURS mpich mvapich2 openmpi3 openmpi4 openmpi)
    for flavour in $(echo $FLAVOURS | sed -e 's/,/ /g'); do
	juLog -name=mpitests_${flavour} test_mpi ${flavour} $HOST1 $IP1 $IP2
    done
}
run_phase 8 phase_8 "MPI"

#########################
#
# Too much unsupported tests
# Phase 9: libfabric
#
#########################


#########################
#
# Phase 10: NVMEoF
#
#########################

phase_10(){
    juLog -name=nvme test_nvme $HOST2 $IP2 $HOST1
}
run_phase 10 phase_10 "nvme"
