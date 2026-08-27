resource "routeros_snmp_community" "monitoring" {
  name        = "homelab-monitor"
  addresses   = ["10.0.20.0/24"]
  read_access = true

  # ADR-027 pass, ground-truthed via a real live plan: RouterOS never
  # returns these over the API (write-only, and this community has no
  # SNMPv3 auth configured -- it's plain v1/v2c), so the provider can't
  # ever confirm they match and re-plans nulling them out on every single
  # run, forever, regardless of live state. Not a real, applicable diff.
  lifecycle {
    ignore_changes = [authentication_password, encryption_password]
  }
}

# WAN monitoring follow-on (Discord voice bufferbloat investigation): named
# "public" so prometheus/snmp_exporter's bundled default snmp.yml (if_mib
# module) works unmodified -- hand-authoring a custom snmp.yml with the
# full ifMIB OID walk redefined just to rename a community string isn't
# worth the added complexity/error surface.
#
# First apply attempt tried to CREATE this and failed: RouterOS already had
# a hand-created "public" community (`/rest/snmp/community`, .id=*0,
# addresses="::/0" -- unrestricted, not in Terraform state, another
# undocumented hand-created object same class as the rest of IAC-GAPS.md).
# Importing it instead of creating a duplicate, and tightening its scope to
# match "homelab-monitor" (10.0.20.0/24, the server VLAN this exporter runs
# in, read-only) in the same change -- closes both the naming collision and
# a real gap (an unrestricted default SNMP community) at once.
resource "routeros_snmp_community" "prometheus_default" {
  name        = "public"
  addresses   = ["10.0.20.0/24"]
  read_access = true

  # See "monitoring" above -- same real, live-confirmed provider quirk.
  lifecycle {
    ignore_changes = [authentication_password, encryption_password]
  }
}

resource "routeros_snmp" "settings" {
  enabled        = true
  contact        = "david@woitzik.dev"
  location       = "Home Lab"
  trap_community = routeros_snmp_community.monitoring.name
}
