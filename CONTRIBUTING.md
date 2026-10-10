# Contributing

Juniper is a small project maintained by one person. Issues and pull requests are welcome;
the maintainer reviews and merges them.

## How changes land

`main` is protected by a repository ruleset:

- **Pull requests only.** Nobody pushes to `main` directly, the maintainer included.
- **Squash merges only.** The PR title becomes the commit subject on `main`.
- **The `lint` check must pass** before a PR can merge. For PRs from forks, lint is all that
  runs (read-only, no secrets); the maintainer builds the images on a branch here before
  merging anything that changes them. A red build is treated as blocking too.
- **No force-pushes or deletion** of `main`.
- **One bypass:** the release job pushes its `docs: changelog for build-…` commit with a
  dedicated write deploy key (`RELEASE_DEPLOY_KEY`). No person and no other workflow can
  bypass the rules.

Dependabot PRs for minor, patch and digest bumps merge themselves once CI is green (through
the same PR rules); major bumps wait for review. See [Release train](README.md#release-train).

## Pull requests

- **Title and commits start with a conventional prefix:** `feat:`, `fix:`, `docs:`, `ci:`,
  `test:`, `chore:`, `build:` or `refactor:` (scope optional, e.g. `fix(ci):`). The title
  matters most, because it becomes the squash commit.
- **Changelog:** note anything that changes behaviour for someone running a Juniper image or
  building `FROM` one under **Unreleased** in [CHANGELOG.md](CHANGELOG.md), in the same PR,
  grouped as Added, Changed, Fixed or Removed. Docs-only changes and dependency bumps don't
  need an entry.
- **Tests:** run `just check` (pre-commit lint and `tests/unit.sh`) before pushing. New
  behaviour in `system_files/usr/libexec/juniper/` or `disk/` gets a test in
  `tests/unit.sh`; checks that need the built image go in `tests/image.sh`. Some things only
  show up on a real Pi (first boot, tryboot, Wi-Fi): say in the PR what you tested on
  hardware.
- **Pin what CI runs.** GitHub Actions are pinned to full commit SHAs with the version as a
  comment (a lint hook enforces it); tool images are pinned by digest (`just bump-tools`,
  `just bump-brew`). Jobs in `build.yml` hold the image signing key, so keep third-party
  code in them to a minimum.
- **Never commit secrets.** Tailscale keys, Wi-Fi passwords and filled-in flash configs stay
  out of the repo; `flash.yaml` and `*.flash.yaml` are gitignored, and
  [`examples/flash.yaml`](examples/flash.yaml) holds placeholders only. Use made-up values in
  tests.

## Building and testing locally

See [Build](README.md#build). Images are arm64; build on an arm64 host or with
qemu-user-static.

## Reporting a security problem

Please don't open a public issue for anything that could put someone's Pi or tailnet at
risk. Use GitHub's private vulnerability reporting on this repository's **Security** tab
("Report a vulnerability") instead.
