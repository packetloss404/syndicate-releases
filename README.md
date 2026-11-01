# Syndicate releases

Signed, binary-only Linux distributions of the private Syndicate coding-agent Host.

Syndicate runs installed Codex, Claude Code and optional Packetcode CLIs on a
Linux machine you control. Its browser dashboard and tmux workstation share
Host-owned sessions and retained Git worktrees. Provider login stays with each
official CLI. Syndicate is standalone.

## Install v0.3.1

The signed [v0.3.1 release](https://github.com/packetloss404/syndicate-releases/releases/tag/v0.3.1)
contains portable Linux x64 and arm64 runtimes built on Ubuntu 24.04, including Node.js. Run the
rootless installer as the intended unprivileged user:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://github.com/packetloss404/syndicate-releases/releases/download/v0.3.1/install.sh \
  | bash -s -- --version v0.3.1
```

This installs Syndicate, its user services and the `~/.local/bin/syndicate`
launcher. It preserves configuration and state on upgrades. Repository roots,
provider installation and provider login are configured separately.

For a fresh Ubuntu 24.04 machine, first create or clone a committed Git
repository owned by the intended user. Run its matched bootstrap from that
repository as a normal user with sudo access:

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://github.com/packetloss404/syndicate-releases/releases/download/v0.3.1/bootstrap-server.sh \
  | sudo bash -s -- --version v0.3.1 --user "$(id -un)" \
      --repository "$PWD" --agents codex,claude --ssh-auto-attach
```

Bootstrap installs system prerequisites and the selected installable agents,
configures the managed HTTPS LAN proxy, enables user services at boot, and
creates the selected tmux workstation. Login remains interactive. Packetcode is
an explicit adopt-only option: it must already be installed. Boot restoration
follows the saved default workstation and provider selection.

For review before execution, download the exact versioned script, inspect it,
and verify its entry in the release's Ed25519-signed `SHA256SUMS` using the
known release public key. Its DER SHA-256 fingerprint is
`285944e7579833efa71bb42be7fe1f584e2c3b79772ea91d5c902f4ccbfb517d`.
Do not mix scripts and runtimes from different releases. Immutable release
assets are authoritative; the installer on `main` is a mutable convenience copy.

## Execution and persistence

The Host binds to loopback; bootstrap's separate proxy supplies LAN HTTPS
access. `syndicate dashboard --no-open` prints a short-lived, single-use browser
URL. Trust the generated local CA on managed clients to remove the certificate
warning.

`workstation attach` reconnects saved session IDs. `workstation recover --detach`
can replace ended or missing processes in their retained workspaces. Recovery
does not promise provider conversation continuation. Detaching or stopping
the tmux presentation leaves native sessions running. Compatible Node Host-only
upgrades preserve PTYs; restarting the native daemon or machine terminates them.

Terminal input executes with the Syndicate Unix user's authority. Worktrees
isolate checkouts, not credentials or processes. Use an unprivileged account
whose repository and credential access you intend to grant. The rootless
installer does not install or authenticate providers, invoke sudo, alter a
firewall, or upload provider credentials.

Each architecture archive includes its source-commit metadata, runtime file
manifest, SPDX SBOM and third-party notices. Both archives and all companion
payloads are covered by `SHA256SUMS` and its Ed25519 signature. The release
pipeline requires the exact main/tag/version identity and successful CI for
that commit, builds and tests both architectures, then verifies the signing
key against the pinned public key before publication.
