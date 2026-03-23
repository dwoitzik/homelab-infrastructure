###############################################################################
# MikroTik Bootstrap for Terraform (Production Ready)
# Description: Prepares a 'no-defaults' RB5009 with SSL REST-API.
# Setup: PKI, User Management, and Management VLAN 10.
###############################################################################

# 1. Create a dedicated group for Terraform
/user group add name=terraform-api policy=read,write,api,rest,test,winbox,password

# 2. Create the Terraform user (Update password before running!)
/user add name=terraform group=terraform-api password="GcNVZn2%6@gARP" comment="Managed by Terraform"

# 3. Network Base: Bridge & Management VLAN
/interface bridge add name=bridge1 vlan-filtering=no comment="Core Bridge"
/interface vlan add interface=bridge1 name=vlan10-mgmt vlan-id=10
/ip address add address=10.0.10.1/24 interface=vlan10-mgmt
/interface bridge port add bridge=bridge1 interface=ether2 pvid=10

# 4. PKI Setup (SSL Certificates)
# Create and sign Root CA
/certificate add name=local-root-cert common-name=local-cert key-usage=key-cert-sign,crl-sign trusted=yes
/certificate sign local-root-cert

# Create and sign Server Certificate for REST-API
/certificate add name=webfig common-name=10.0.10.1 days-valid=3650 key-usage=digital-signature,key-agreement,tls-server trusted=yes
/certificate sign ca=local-root-cert webfig

# 5. Enable Secure REST-API
/ip service set www-ssl certificate=webfig disabled=no port=443
/ip service set www disabled=yes
