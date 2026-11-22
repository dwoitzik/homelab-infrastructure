# WAN upload shaping (bufferbloat). A queue tree on ether1 also shapes
# FastTrack'ed packets and never sees inter-VLAN traffic; 68M of the 75 Mbit
# upload keeps this queue, not the modem's buffer, as the bottleneck.
resource "routeros_queue_type" "cake_wan_up" {
  name          = "cake-wan-up"
  kind          = "cake"
  cake_diffserv = "diffserv4"
  cake_nat      = true
  cake_flowmode = "dual-srchost"
}

# A queue tree leaf with an empty packet-mark receives no packets at all;
# "no-mark" is what matches unmarked traffic.
resource "routeros_queue_tree" "wan_up" {
  name        = "wan-up"
  parent      = "ether1"
  packet_mark = ["no-mark"]
  max_limit   = "68000000"
  queue       = routeros_queue_type.cake_wan_up.name
  comment     = "SQM: CAKE on WAN upload (bufferbloat)"
}

# ether1 also leads to the Fritzbox LAN, which never touches the ISP uplink: a
# marked packet matches no queue tree leaf and leaves at line rate (4K remux
# needs ~95M). Relies on the FastTrack exclusion in firewall_deterministic.tf.
resource "routeros_ip_firewall_mangle" "lan_bypass_wan_shaper" {
  chain           = "postrouting"
  action          = "mark-packet"
  new_packet_mark = "lan-bypass"
  passthrough     = false
  out_interface   = "ether1"
  dst_address     = "192.168.178.0/24"
  comment         = "QoS: Fritzbox LAN traffic bypasses the WAN upload shaper"
}
