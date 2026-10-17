# Tailscale, lockdown and LAN SSH

## The auth key and your tailnet policy

Create a **tagged**, one-off, pre-approved auth key at
<https://login.tailscale.com/admin/settings/keys>. Pick a short expiry that matches when you
will deploy; the device deletes an unused key after 14 days or as soon as Tailscale rejects
it. Tagged devices never expire, so the lockdown can't lock you out later.

The key turns on Tailscale SSH, so your [tailnet policy](https://tailscale.com/kb/1337/policy-syntax)
needs to let you in to that tag. Keep it narrow: an admin group, SSH as your login user only
(no root: use `sudo`), and only the ports you use, in place of the default allow-all rule (a
`tcp:22`-only grant also blocks ICMP and every other port, so add the ports for the services
you run). For example (`you` is the `user` in your flash config):

```json
{
  "groups": {"group:admins": ["alice@example.com"]},
  "tagOwners": {"tag:server": ["group:admins"], "tag:monitoring": ["group:admins"]},
  "grants": [
    {"src": ["group:admins"], "dst": ["tag:server"], "ip": ["tcp:22"]},
    {"src": ["tag:monitoring"], "dst": ["tag:server"], "ip": ["tcp:9100"]}
  ],
  "ssh": [
    {"action": "check", "src": ["group:admins"], "dst": ["tag:server"], "users": ["you"]}
  ]
}
```

`check` asks you to re-authenticate in the browser every 12 hours; use `accept` only for
automation (a tagged CI or backup device) with its own narrow rule.
`"users": ["autogroup:nonroot"]` also works, but lets the admin group log in as any non-root
account on the Pi. The second grant is for `ujust enable-metrics` (node_exporter on :9100)
from a monitoring host tagged `tag:monitoring`; drop it if you don't use it. See
[grants](https://tailscale.com/kb/1324/grants) and
[Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh).

## Lockdown

Until the Pi has joined your tailnet, SSH is open on whatever network it is on. That is a
deliberate choice: if the Tailscale join fails, you can still reach the Pi over the LAN to
fix it. Once it joins, a lockdown makes the firewall drop everything except Tailscale, and
LAN SSH is closed. `ujust lan-ssh` only matters after lockdown.

## LAN SSH, if Tailscale goes away

Re-open SSH without exposing it to the internet:

    ujust lan-ssh                       # show the state: off, scoped, or legacy-unscoped
    ujust lan-ssh on                    # allow SSH from the networks this Pi is directly on
    ujust lan-ssh on 192.168.1.0/24     # or only from the CIDRs you give (IPv4 or IPv6)
    ujust lan-ssh for 2h                # same, but runtime only: expires after 2h or on reboot
    ujust lan-ssh off                   # close it again

By default `on` and `for` allow the on-link prefixes of every non-Tailscale interface (IPv4
and IPv6, including link-local and your router-advertised global /64), never the internet.
Container and VM bridges (`podman*`, `docker*`, `veth*`, `cni*`, `cali*`, `flannel*`,
`virbr*`) are skipped: local containers don't need the Pi's sshd.

Sources are fixed at the moment you run it: re-run it after moving the Pi to another
network. `for` needs a unit (`30s`, `30m`, `2h`); `on` and `off` cancel an active `for`
window (a network that is already open keeps its original expiry if you run `for` again).
CIDRs broader than /8 (IPv4) or /16 (IPv6), including `0.0.0.0/0` and `::/0`, are refused
unless you add `--force`.

Older images' `ujust lan-ssh on` opened SSH to every network; the login banner and
`ujust pi-status` warn while that rule is still there, and `ujust lan-ssh on` or `off`
removes it. Nothing changes it automatically on update.
