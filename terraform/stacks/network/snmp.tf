resource "routeros_snmp_community" "monitoring" {
  name        = "homelab-monitor"
  addresses   = ["10.0.20.0/24"]
  read_access = true
}

resource "routeros_snmp" "settings" {
  enabled        = true
  contact        = "david@woitzik.dev"
  location       = "Home Lab"
  trap_community = routeros_snmp_community.monitoring.name
}
