# 🔐 Proxmox SSO Setup (Authelia OIDC)

To enable SSO for Proxmox VE and Proxmox Backup Server, you need to configure the OIDC Realm in their respective web interfaces.

## 1. Proxmox VE (PVE)
1. Log in to your PVE web interface ([pve.woitzik.dev](https://pve.woitzik.dev)).
2. Go to **Datacenter** > **Permissions** > **Realms**.
3. Click **Add** and select **OpenID Connect Server**.
4. Use the following settings:
   - **Realm ID**: `authelia`
   - **Issuer URL**: `https://auth.woitzik.dev`
   - **Client ID**: `proxmox`
   - **Client Key**: `<YOUR_GENERATED_SECRET>`
   - **Autocreate Users**: Check this box.
   - **Username Claim**: `preferred_username` (or `email`)
   - **Scopes**: `openid profile email groups`
   - **Prompt**: `none` (or leave empty)
5. Click **Add**.
6. **Important**: You need to give your user/group permissions. Go to **Datacenter** > **Permissions** and add a group or user permission for the new realm (e.g., `david@authelia` with `Administrator` role).

## 2. Proxmox Backup Server (PBS)
1. Log in to your PBS web interface ([backup.woitzik.dev](https://backup.woitzik.dev)).
2. Go to **Configuration** > **Access Control** > **Realms**.
3. Click **Add** and select **OpenID Connect**.
4. Use the following settings:
   - **Realm ID**: `authelia`
   - **Issuer URL**: `https://auth.woitzik.dev`
   - **Client ID**: `pbs`
   - **Client Key**: `<YOUR_GENERATED_SECRET>`
   - **Autocreate Users**: Check this box.
   - **Username Claim**: `preferred_username`
   - **Scopes**: `openid profile email groups`
5. Click **Add**.

## 3. Minio SSO
- When you open [minio.woitzik.dev](https://minio.woitzik.dev), you should see a button **"Login with OpenID"**.
- Click that button to be redirected to Authelia.

## 4. Argo CD SSO
- On the Argo CD login page ([argo.woitzik.dev](https://argo.woitzik.dev)), there should be a button **"LOG IN VIA AUTHELIA"**.
- Click it to sign in with your lab credentials.
