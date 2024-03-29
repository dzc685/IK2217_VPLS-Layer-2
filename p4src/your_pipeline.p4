/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

//My includes 
#include "include/headers.p4"
#include "include/parsers.p4"

const bit<16> L2_LEARN_ETHER_TYPE = 0x1234;
const bit<16> RTT_ETHER_TYPE = 0x5678;

/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {
    apply {  }
}

/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {
    action drop() {
        mark_to_drop();
    }

    action forward (egressSpec_t port) {
        standard_metadata.egress_spec = port;
    }

    action encap_forward (egressSpec_t port, tunnel_id_t tunnel_id, pw_id_t pw_id) {
        hdr.ethernet_encap.setValid();
        hdr.ethernet_tunnel.setValid();

        hdr.ethernet_encap = hdr.ethernet;
        hdr.ethernet.etherType = TYPE_TUNNEL;
        hdr.tunnel.tunnel_id = tunnel_id;
        hdr.tunnel.pw_id = pw_id;

        standard_metadata.egress_spec = port;
    }

    action decap_forward (egressSpec_t port) {
        hdr.ethernet.etherType = hdr.ethernet_encap.etherType;
        hdr.ethernet_encap.setInvalid();
        hdr.tunnel.setInVailid();

        standard_metadata.egress_spec = port;
    }


    //TASK 1 : normal forwarding table
    table forward_table {
        key = {
            standard_metadata.ingress_port: exact;
            hdr.ethernet.dstAddr: exact;
        }
        actions = {
            forward;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    table encap_forward_table {
        key = {
            standard_metadata.ingress_port: exact;
            hdr.tunnel.tunnel_id: exact;
            hdr.tunnel.pw_id: exact;
        }
        actions = {
            encap_forward;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    table decap_forward_table {
        key = {
            standard_metadata.ingress_port: exact;
            hdr.tunnel.pw_id: exact;
        }
        actions = {
            decap_forward;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    //TASK 2: ECMP
    action ecmp_group (bit<14> ecmp_group_id, bit<16> num_nhops) {
        hash(meta.ecmp_hash,
            HashAlgorithm.crc32,
            (bit<1>)0,
            {hdr.ipv4.srcAddr, hdr.ipv4.dstAddr, hdr.tcp.srcPort, hdr.tcp.dstPort, hdr.ipv4.protocol},
            num_nhops);
        meta.ecmp_group_id = ecmp_group_id;
    }
    action set_nhop(macAddr_t srcAddr, macAddr_t dstAddr, egressSpec_t port) {
        hdr.ethernet.srcAddr = srcAddr;
        hdr.ethernet.dstAddr = dstAddr;
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    table ecmp_group_to_nhop {
        key = {
            meta.ecmp_group_id: exact;
            meta.ecmp_hash: exact;
        }
        actions = {
            drop;
            set_nhop;
        }
        size = 1024;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            set_nhop;
            ecmp_group;
            drop;
        }
        size = 1024;
        default_action = drop;
    }

    //TASK 3 : multicasting
    action set_mcast_grp(bit<16> mcast_grp) {
        standard_metadata.mcast_grp = mcast_grp;
    }

    table customer_flooding { //包从相邻客户主机接收
        key = {
            standard_metadata.ingress_port : exact;
            hdr.tunnel.pw_id : exact;
        }
        actions = {
            set_mcast_grp;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    table tunnel_flooding { //包通过隧道从另一PE设备接收
        key = {
            hdr.tunnel.tunnel_id : exact;
        }
        actions = {
            set_mcast_grp;
            NoAction;
        }
        size = 1024;
        default_action = NoAction;
    }

    //TASK 4 : L2 learning
    action mac_learn() {
        meta.ingress_port = standard_metadata.ingress_port;
        clone3(CloneType.I2E, 100, meta);
    }
    table learning_table {
        key = {
            hdr.ethernet.srcAddr: exact;
            standard_metadata.ingress_port: exact;
        }
        actions = {
            mac_learn;
            NoAction;
        }
        size = 1024;
        default_action = mac_learn;
    }

    table encap_learning_table {
        key = {
            hdr.ethernet.srcAddr: exact;
            hdr.tunnel.pw_id: exact;
        }
        actions = {
            mac_learn;
            NoAction;
        }
        size = 1024;
        default_action = mac_learn;
    }

    apply {
       //L2学习
        if (hdr.ethernet.srcAddr.isValid()) {
            if (hdr.tunnel.isValid()) {
                encap_learning_table.apply();
            } else {
                learning_table.apply();
            }
        }

        //ECMP
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();
            if (meta.ecmp_group_id.isValid()) {
                ecmp_group_to_nhop.apply();
            }
        }

        // 检查是否需要封装或解封装
        if (hdr.tunnel.isValid()) {
            decap_forward_table.apply();
        } else {
            encap_forward_table.apply();
        }

        // 基于目的MAC地址的正常转发
        forward_table.apply();

        //广播场景
        //包从相邻客户主机接收
        if (standard_metadata.ingress_port.isValid() && !hdr.tunnel.isValid()) {
            customer_flooding.apply();
        }
        //包通过隧道从另一PE设备接收
        if (hdr.tunnel.isValid()) {
            tunnel_flooding.apply();
        }
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    
    action drop_2(){
        mark_to_drop();
    }
    apply {
        if (standard_metadata.instance_type == 1){
            hdr.cpu.setValid();
            hdr.cpu.srcAddr = hdr.ethernet.srcAddr;
            hdr.ethernet.etherType = L2_LEARN_ETHER_TYPE;
            if (hdr.tunnel.isValid()) {
                hdr.cpu.tunnel_id = hdr.tunnel.tunnel_id;
                hdr.cpu.pw_id = hdr.tunnel.pw_id;
                hdr.cpu.ingress_port = 0;
            } else {
                hdr.cpu.tunnel_id = 0;
                hdr.cpu.pw_id = 0;
                hdr.cpu.ingress_port = (bit<16>)meta.ingress_port;
            truncate((bit<32>)22);
            }
        }else if (standard_metadata.egress_rid != 0) {
            hdr.ethernet_encap.setValid();
            hdr.tunnel.setValid();
            hdr.ethernet_encap = hdr.ethernet;
            hdr.ethernet.etherType = TYPE_TUNNEL;
            hdr.tunnel.tunnel_id = meta.tunnel_id;
            hdr.tunnel.pw_id = meta.pw_id;
        }
    }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers hdr, inout metadata meta) {
     apply {
	update_checksum(
	    hdr.ipv4.isValid(),
            { hdr.ipv4.version,
	          hdr.ipv4.ihl,
              hdr.ipv4.dscp,
              hdr.ipv4.ecn,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
              hdr.ipv4.hdrChecksum,
              HashAlgorithm.csum16);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

//switch architecture
V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
