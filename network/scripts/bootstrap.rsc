###############################################################################
# MikroTik Bootstrap for Terraform (Production Ready)
# Description: Prepares a 'no-defaults' RB5009 with SSL REST-API.
# Setup: PKI, User Management, and Management VLAN 10.
###############################################################################

# 1. Create a dedicated group for Terraform
/user group add name=terraform-api policy=read,write,api,rest,test,winbox,password

# 2. Create the Terraform user
# SEC-015: this line previously had a real, live password hardcoded here --
# leaked in git history for months (2026-03 - 2026-07) in a public repo, and
# was the actual password Atlantis used to manage this router the whole
# time, since this user was never brought under Terraform management
# (no routeros_user resource exists for it). Rotated 2026-07-06. Generate a
# fresh password out-of-band (`openssl rand -base64 24`) and set it directly
# on the router via Winbox/SSH as admin -- never commit a real value here.
/user add name=terraform group=terraform-api password="CHANGE_ME_SET_VIA_WINBOX_NOT_GIT" comment="Managed by Terraform"

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
