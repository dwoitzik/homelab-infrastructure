###############################################################################
# Power Efficiency — MikroTik RB5009
###############################################################################
#
# Active ports:  ether1 (WAN), ether2 (Admin), ether5 (Proxmox),
#                ether6 (RPi-01), ether7 (RPi-02)
# Unused ports:  ether3, ether4, ether8, sfpplus1
#
# Disabling unused ports at boot reduces power draw by ~0.1-0.2W per port
# and prevents accidental L2 loops. Re-enable manually if a port is needed:
#   /interface ethernet enable ether3
###############################################################################

resource "routeros_system_scheduler" "disable_unused_ports" {
  name       = "power_disable_unused_ports"
  start_time = "startup"
  interval   = "0s"
  on_event   = <<-EOF
    /interface ethernet disable ether3
    /interface ethernet disable ether4
    /interface ethernet disable ether8
    /interface ethernet disable sfpplus1
  EOF
  comment    = "Power: disable unused ethernet ports at boot"
}
