# Proxmox SSO Setup (Authelia OIDC)

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

## 3. Argo CD SSO

- On the Argo CD login page ([argo.woitzik.dev](https://argo.woitzik.dev)), there should be a button **"LOG IN VIA AUTHELIA"**.
- Click it to sign in with your lab credentials.

## 4. Immich (Cloudflare Access OIDC)

Authelia is the lab IdP for infrastructure operators, but Immich is shared with
family members who have no Authelia account. Immich therefore uses a separate
**Cloudflare Access SaaS/OIDC application** with One-time-PIN login, restricted
to a family email allowlist. It is an **identity provider only** -- not a
request gate in front of the app (that approach broke native mobile clients,
see [immich#8299](https://github.com/immich-app/immich/discussions/8299)).
The tunnel ingress (`terraform/stacks/cloudflare/main.tf`) delivers Immich
directly.

The Access application is **not managed by Terraform**: the Cloudflare stack's
API token has no Zero Trust Access permission (`403 auth.forbidden` on
`/access/apps`). It is created via the Cloudflare admin API / dashboard.

### Cloudflare Access application

| Setting | Value |
| --- | --- |
| Name | `Immich OIDC (photos.woitzik.dev)` |
| Type | `saas`, auth type `oidc` |
| Team domain | `woitzik.cloudflareaccess.com` |
| App / client ID | `d4b3d44dfed7195381aa40491e54dbc72885da00a533931d23ba66cce6cab5a0` |
| Issuer URL | `https://woitzik.cloudflareaccess.com/cdn-cgi/access/sso/oidc/d4b3d44dfed7195381aa40491e54dbc72885da00a533931d23ba66cce6cab5a0` |
| Scopes | `openid`, `email` |
| Grant types | `authorization_code` (no PKCE) |
| Redirect URIs | `https://photos.woitzik.dev/auth/login`, `https://photos.woitzik.dev/user-settings`, `https://photos.woitzik.dev/api/oauth/mobile-redirect` |
| Policy | `Family email OTP (Immich OIDC)`, decision `allow` |
| Allowed emails | `woitzikdavid18@gmail.com`, `goraadrian28@gmail.com`, `dwoitzik50@gmail.com` |

The client secret is not committed to this repo; it lives in Immich's
SystemConfig (Admin > Settings > OAuth). Rotate it in the Cloudflare dashboard
and update it there if needed.

### Immich OAuth settings

Admin > Settings > OAuth, or via `PUT /api/system-config`:

- **Issuer URL**: as above
- **Client ID**: as above
- **Client secret**: value from the Cloudflare app
- **Mobile redirect override**: enabled, `https://photos.woitzik.dev/api/oauth/mobile-redirect`
- **Auto-register**: disabled (accounts must already exist; the OIDC `email`
  claim is matched against the Immich account email)
- **Auto-launch**: optional (`false` keeps the password form visible during
  the transition)

The redirect URIs must be registered on the Access app or Cloudflare returns an
`invalid redirect_uri` error before login.
