###############################################################################
# MikroTik Bootstrap for Terraform
# Run this manually once to enable API access
###############################################################################

# 1. Create a dedicated group for Terraform with necessary permissions
/user group add name=terraform-api policy=read,write,api,rest,test,winbox,password

# 2. Create the Terraform user (CHANGE THE PASSWORD IMMEDIATELY)
/user add name=terraform group=terraform-api password="CHANGE_ME_SECURE_PASSWORD" comment="Managed by Terraform"

# 3. Enable the REST-API (www-ssl)
# Note: This assumes you might not have a certificate yet,
# Terraform will use 'insecure = true' for the initial connection.
/ip service set www-ssl disabled=no port=443

# 4. (Optional) Set a static IP for Management if not already done
# Adjust 'ether2' and the IP to your local admin connection
# /ip address add address=10.0.10.1/24 interface=ether2 network=10.0.10.0
