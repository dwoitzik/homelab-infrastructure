resource "routeros_snmp_community" "monitoring" {
  name        = "homelab-monitor"
  addresses   = ["10.0.20.0/24"]
  read_access = true
}

# WAN monitoring follow-on (Discord voice bufferbloat investigation): named
# "public" so prometheus/snmp_exporter's bundled default snmp.yml (if_mib
# module) works unmodified -- its default auth block expects a community
# literally named "public", and hand-authoring a custom snmp.yml with the
# full ifMIB OID walk redefined just to rename a community string isn't
# worth the added complexity/error surface for a read-only, address-scoped
# grant. Same restriction as the existing "homelab-monitor" community
# (10.0.20.0/24, the server VLAN this exporter runs in, read-only) --
# doesn't touch or weaken it, just adds a second read-only grant.
resource "routeros_snmp_community" "prometheus_default" {
  name        = "public"
  addresses   = ["10.0.20.0/24"]
  read_access = true
}

resource "routeros_snmp" "settings" {
  enabled        = true
  contact        = "david@woitzik.dev"
  location       = "Home Lab"
  trap_community = routeros_snmp_community.monitoring.name
}
