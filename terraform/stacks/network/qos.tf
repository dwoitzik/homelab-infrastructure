# WAN upload shaping (bufferbloat). A queue tree on ether1 also shapes
# FastTrack'ed packets and never sees inter-VLAN traffic; 45M of the 50 Mbit
# upload keeps this queue, not the modem's buffer, as the bottleneck.
resource "routeros_queue_type" "cake_wan_up" {
  name          = "cake-wan-up"
  kind          = "cake"
  cake_diffserv = "diffserv4"
  cake_nat      = true
  cake_flowmode = "dual-srchost"
}

resource "routeros_queue_tree" "wan_up" {
  name      = "wan-up"
  parent    = "ether1"
  max_limit = "45M"
  queue     = routeros_queue_type.cake_wan_up.name
  comment   = "SQM: CAKE on WAN upload (bufferbloat)"
}
