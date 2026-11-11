# ADR-072: unattended-upgrades covers the third-party repositories

## Status

Accepted and applied, 2026-10-22.

## Context

`unattended-upgrades` was installed and enabled on every host, and the
`unattended-upgrades.log` showed it running daily and installing packages. The
Debian hosts were clean as a result: 0 to 6 pending upgrades on the k3s nodes,
the NFS server and Atlantis.

The Pi nodes were not. They had **69 pending updates** and the count was not
moving. The `unattended-upgrades` log made the reason visible:

```text
INFO Allowed origins are: origin=Debian,codename=trixie,label=Debian,
     origin=Debian,codename=trixie,label=Debian-Security,
     origin=Debian,codename=trixie-security,label=Debian-Security
```

Only Debian. The Pi nodes carry four more repositories — Raspberry Pi
Foundation, Docker CE, Tailscale and AZlux — and the packages from those were
never candidates. What sat unapplied included `docker-ce` (29.5.0 installed,
29.9.2 available), `containerd.io` (2.2.3 installed, 2.4.2 available),
`libc6`, `openssl` and the Raspberry Pi firmware packages.

That matters because of containerd. The installed 2.2.3 is affected by
CVE-2026-50195 (9.9 critical, local image tag poisoning via CRI checkpoint
import), CVE-2026-53492, CVE-2026-47262, CVE-2026-95837 (7.8 high) and
CVE-2026-95838. All of them are fixed in 2.2.5, 2.2.7 and 2.2.8 respectively;
the packaged 2.4.2 carries every one of those fixes.

The `allowed origins` list is not just a filter, it is also the place where a
malformed entry breaks the service: unattended-upgrades refuses to start when
it cannot parse the pattern, and the stock pattern on these hosts contains an
entry naming a label that does not exist.

## Decision

**Replace the origins pattern with one that names every repository the host
actually uses, and let unattended-upgrades install their packages too.**

The pattern is written in the `common` role, which runs on every managed host.
The three third-party entries need different match fields, because the
repositories do not publish the same metadata:

| Repository | Origin | Label | Suite | Codename | Pattern |
|---|---|---|---|---|---|
| Raspberry Pi Foundation | `Raspberry Pi Foundation` | same | `stable` | `trixie` | `origin=...,codename=${distro_codename},label=...,c=main` |
| Docker CE | `Docker` | `Docker CE` | `trixie` | *(absent)* | `origin=Docker,label=Docker CE,c=stable` |
| Tailscale | `Tailscale` | `Tailscale` | *(absent)* | `bookworm` | `origin=Tailscale,codename=bookworm,label=Tailscale,c=main` |

The Debian entries are kept, with the invalid stock one replaced by the
`${distro_codename}-updates` variant that the hosts actually serve.

Matching was verified empirically rather than assumed: `unattended-upgrade
--dry-run --debug` reports the allowed origins and the resulting package list,
and the field combination for each repository was taken from
`apt-get indextargets`, which reports origin, label, suite, codename and
component per index. Two earlier attempts failed exactly there — matching
Docker on `codename=` finds nothing because that repository publishes no
codename, and matching it on `n=` finds nothing because `n=` is the codename
field, not the suite.

## Consequences

- The Pi nodes now install their own updates unattended, including Docker
  Engine, containerd, Tailscale and the firmware packages.
- **A Docker Engine or containerd update restarts the daemon**, which stops
  every container on that node. On the Pi nodes that means AdGuard and Unbound
  go down for a moment. The pair is a keepalived HA set, so the VIP moves to
  the other node, but the two containers on the node being updated still
  restart. This is accepted: the alternative is a runtime that stays a year
  behind on published security fixes.
- **Kernel and firmware updates still need a reboot** to take effect.
  unattended-upgrades installs them and writes `/var/run/reboot-required`; it
  does not reboot on its own, and `Automatic-Reboot` stays off because an
  unattended reboot of the DNS and proxy nodes is not acceptable here.
  Reboots stay a deliberate, announced step.
- The k3s cluster is not covered by this. It runs containerd inside the k3s
  binary, so the packaged `containerd.io` version says nothing about it, and
  its containerd 2.0.5 is fixed only by a k3s upgrade — a separate piece of
  work with a larger blast radius than a package update.
- The `common` role is used on hosts with different repository sets. A host
  without the Docker or Tailscale repository simply has no packages from it,
  and an origin that matches nothing is not an error.
