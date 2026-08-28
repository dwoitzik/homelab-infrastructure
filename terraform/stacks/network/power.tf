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
# LED scheduling — REMOVED 2026-08-26 (was: cosmetic, off 22:00-06:00 local)
###############################################################################
#
# Live RB5009 (RouterOS 7.19.4) started getting stuck with LEDs off past
# 06:00 -- the day-mode scheduler's on-event kept its run-count incrementing
# (so the schedule itself fired), but the LEDs didn't come back. Confirmed
# separately that a live write to all-leds-off (either "no" or "false") via
# the REST API 500s outright -- RouterOS itself errors on this write, not a
# policy/script issue. Matches a known class of RB5009 LED-subsystem
# regressions seen across other RouterOS versions -- not chasing a firmware
# bug for a feature that saves ~0W and only exists for looks. Live scheduler
# entries (night_mode_leds / day_mode_leds on the router -- note the live
# name never matched this file's declared resource names, pre-existing
# drift) need removing via Atlantis apply of this PR -- a direct REST write
# against them hit "policy does not allow to edit this script" for this API
# user, so cleanup goes through the normal apply path, not a manual call.
# LEDs stay off until that apply runs (or the router is rebooted, which also
# clears it).
###############################################################################

###############################################################################
# LED scheduling — re-added 2026-08-27, cosmetic, off 22:00-06:00 local
###############################################################################
#
# The RB5009 firmware bug documented above is genuinely fixed on RouterOS
# 7.24.1 (confirmed live: `GET /rest/system/resource` -> version 7.24.1,
# past the 7.22.2 fix that resolved it). Rebuilding the original off-hours
# schedule (#493) with the values this firmware actually accepts.
#
# Interim step, superseded by this: right after confirming the firmware
# fix, `all-leds-off` was captured into Terraform as a static
# `routeros_system_led_settings` resource pinned to "never" (LEDs always
# on) -- a snapshot of the live emergency fix, not the real feature. That
# static resource is removed here rather than kept alongside these
# schedulers: a static declared value and a scheduler that changes the
# same field twice a day would fight each other on every apply (the same
# "two mechanisms managing one live object" bug that caused the original
# main.tf/power.tf collision this repo already hit once, see #570) --
# picking one mechanism (the scheduler) instead of layering both.
#
# Same raw-script `routeros_system_scheduler` pattern as
# disable_unused_ports above, matching the original #493 design (not the
# typed `routeros_system_led_settings` resource, to avoid a second
# collision risk between it and the scheduler's own writes).
#
# Value change from the original: "no" -> "never" for the day-mode
# (LEDs-on) state. On RouterOS 7.19.4 `all-leds-off` accepted "no"/"yes"
# (and even "no" 500'd, which is what broke this feature in the first
# place). On 7.24.1 the accepted values are "never"/"immediate" --
# confirmed live: "no" now 400s with "input does not match any value",
# "never" succeeds. "immediate" (the night-mode/LEDs-off value) was valid
# on both versions, unchanged. A real RouterOS-version-driven schema
# change, not this repo's own inconsistency.
###############################################################################

resource "routeros_system_scheduler" "led_off_night" {
  name       = "power_led_off_night"
  start_time = "22:00:00"
  interval   = "1d"
  on_event   = "/system leds settings set all-leds-off=immediate"
  comment    = "Cosmetic: turn off board LEDs 22:00-06:00"
}

resource "routeros_system_scheduler" "led_on_day" {
  name       = "power_led_on_day"
  start_time = "06:00:00"
  interval   = "1d"
  on_event   = "/system leds settings set all-leds-off=never"
  comment    = "Cosmetic: restore board LEDs at 06:00"
}
