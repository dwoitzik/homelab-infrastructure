###############################################################################
# MikroTik Bootstrap for Terraform
# Description: Prepares a 'no-defaults' RB5009 for Terraform management.
# Setup: Enables REST-API and provides IP connectivity on ether2 (VLAN 10).
###############################################################################

# 1. Create a dedicated group for Terraform with necessary permissions
/user group add name=terraform-api policy=read,write,api,rest,test,winbox,password

# 2. Create the Terraform user (CHANGE THE PASSWORD!)
/user add name=terraform group=terraform-api password="YOUR_SECURE_PASSWORD" comment="Managed by Terraform"

# 3. Create the Base Bridge (Required for VLAN filtering later)
/interface bridge add name=bridge1 vlan-filtering=no comment="Core Bridge"

# 4. Define Management VLAN (VLAN 10)
/interface vlan add interface=bridge1 name=vlan10-mgmt vlan-id=10

# 5. Assign Management IP to the Router
/ip address add address=10.0.10.1/24 interface=vlan10-mgmt

# 6. Bridge ether2 to VLAN 10 (Access Port for Admin PC)
/interface bridge port add bridge=bridge1 interface=ether2 pvid=10

# 7. Enable the REST-API (www-ssl) for Terraform communication
/ip service set www-ssl disabled=no port=443