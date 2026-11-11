# WAN upload shaping (bufferbloat). 68M is ~90% of the measured 74 Mbit/s upload,
# keeping this queue, not the modem's, as the bottleneck. It only works because
# fwd_00_fasttrack skips WAN connections; FastTrack bypasses all queues.
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
  max_limit = "68000000"
  queue     = routeros_queue_type.cake_wan_up.name
  comment   = "SQM: CAKE on WAN upload (bufferbloat)"
}
