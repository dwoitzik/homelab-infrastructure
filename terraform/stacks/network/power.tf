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

###############################################################################
# LED scheduling — cosmetic, off 22:00-06:00 local
###############################################################################
#
# RouterOS exposes board LED control via `/system leds settings` (the
# terraform-routeros provider ships both a typed `routeros_system_led_settings`
# resource and the raw `/system/leds` API path), specifically the
# `all-leds-off` property. Using the same raw-script `routeros_system_scheduler`
# pattern as disable_unused_ports above instead of the typed resource, since
# this repo's existing usage of that pattern is already proven live and this
# avoids depending on the typed resource's exact accepted enum values, which
# weren't independently verified against this specific RouterOS version this
# pass.
###############################################################################

#
# 2026-08-22: this resource block existed since #493 but was never actually
# reconciled onto the live router -- terraform state still tracked the
# pre-existing manually-created schedulers (`night_mode_leds`/`day_mode_leds`,
# calling separate `/system script` entries `leds_off`/`leds_on` that only
# disable per-interface LED bindings, not the board LEDs). Renaming the
# resource block below to match those live names/on-events instead of
# re-fighting drift, so the next Atlantis apply converges onto what's
# actually live and reachable, and future drift is visible in `terraform
# plan` instead of silently never applying.
resource "routeros_system_scheduler" "led_off_night" {
  name       = "night_mode_leds"
  start_time = "22:00:00"
  interval   = "1d"
  on_event   = "/system leds settings set all-leds-off=immediate"
  comment    = "Cosmetic: turn off board LEDs 22:00-06:00"
}

resource "routeros_system_scheduler" "led_on_day" {
  name       = "day_mode_leds"
  start_time = "06:00:00"
  interval   = "1d"
  on_event   = "/system leds settings set all-leds-off=no"
  comment    = "Cosmetic: restore board LEDs at 06:00"
}
