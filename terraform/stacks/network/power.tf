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
# LED state — captured into Terraform 2026-08-27, ADR-027 pass
###############################################################################
#
# The RB5009 firmware bug documented above is genuinely fixed on RouterOS
# 7.24.1 (confirmed live: `GET /rest/system/resource` -> version 7.24.1,
# past the 7.22.2 fix). The router was moved to `all-leds-off: never`
# directly (not via this file) to unblock the "LEDs stuck off" symptom
# immediately -- this declares that live value so a future apply doesn't
# silently revert it, matching what's actually running rather than what
# the removed scheduler used to try to do.
#
# Deliberately NOT re-adding the night/day off-hours schedule the old
# scheduler tried to run -- that's a real feature decision (worth doing now
# that the underlying write bug is fixed), not a declared-vs-live
# reconciliation. Left for the operator, see `phase8/QUESTIONS.md`.
#
# Also note the value itself: on 7.19.4 this field only accepted "no"/"yes"
# (and even those 500'd, see above) -- on 7.24.1 the accepted values
# changed to "never"/"immediate" (confirmed live: "no" now 400s with
# "input does not match any value"). A real RouterOS-version-driven schema
# change, not this repo's own inconsistency.
###############################################################################

resource "routeros_system_led_settings" "power" {
  all_leds_off = "never"
}
