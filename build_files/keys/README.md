# Pinned RPM signing keys

`build.sh` trusts these files, not whatever the repositories' HTTPS servers return at build
time. Each fingerprint below was checked against a source other than the server the key was
downloaded from.

| File | Key | Fingerprint |
| --- | --- | --- |
| `RPM-GPG-KEY-EPEL-10` | Fedora (epel10) `<epel@fedoraproject.org>`, rsa4096, 2023-12-12 | `7D8D 15CB FC4E 6268 8591 FB26 33D9 8517 E37E D158` |
| `RPM-GPG-KEY-tailscale` | Tailscale Inc. (Package repository signing key) `<info@tailscale.com>`, rsa4096, 2020-02-25 | `2596 A99E AAB3 3821 893C 0A79 458C A832 957F 5868` |

Sources (checked 2026-10-11):

- **EPEL 10**: downloaded from
  `https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-10`. Fingerprint matches
  [Fedora's security page](https://fedoraproject.org/security/) and the DNSSEC-validated
  OPENPGPKEY record for `epel@fedoraproject.org`
  (`1a355c3f…015ec._openpgpkey.fedoraproject.org`, `delv` "fully validated").
- **Tailscale**: downloaded from `https://pkgs.tailscale.com/stable/rhel/10/repo.gpg`.
  Tailscale doesn't publish the fingerprint in its documentation; it matches the key served
  by `keyserver.ubuntu.com` and `keys.openpgp.org` (second fetch paths, not an attestation
  by Tailscale).

What is and isn't signed: package signatures are checked against the keys above for every
repository (`gpgcheck=1`), but only the Tailscale repository's metadata is signed too
(`repo_gpgcheck=1`). EPEL, AlmaLinux and CRB metadata isn't gpg-checked; it is authenticated
only by the metalink/HTTPS transport. A compromised mirror or TLS path can therefore withhold
or roll back updates, or hide a fix, but cannot get an unsigned or wrongly signed package
installed.

How they're used:

- EPEL: `build.sh` downloads `epel-release`, verifies its signature against
  `RPM-GPG-KEY-EPEL-10` alone (a throwaway rpm database, signature required), then installs
  it. The verified package ships EPEL's repo files, whose `gpgkey=` is already a local file.
- Tailscale: `build.sh` installs the key as `/etc/pki/rpm-gpg/RPM-GPG-KEY-tailscale` and
  `build_files/tailscale.repo` (`gpgcheck=1`, `repo_gpgcheck=1`, `gpgkey=file://`).

To refresh a key (it was rotated, or a build fails its signature check): see
[CONTRIBUTING.md](../../CONTRIBUTING.md#pinned-keys).
