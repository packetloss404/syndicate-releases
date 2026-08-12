# Syndicate releases

Signed, binary-only Linux releases for the private Syndicate coding-agent host.

Syndicate turns an owned Linux server into a private coding-agent powerhouse. PacketADE remains the flagship desktop UI; the Host executes installed Codex, Claude Code, PacketCode, and shell panes under the server user's authority.

## Install v0.1.0

Review the immutable installer first:

```bash
curl --proto '=https' --tlsv1.2 -fsSLo /tmp/syndicate-install.sh \
  https://github.com/packetloss404/syndicate-releases/releases/download/v0.1.0/install.sh
less /tmp/syndicate-install.sh
bash /tmp/syndicate-install.sh --version v0.1.0
```

The installer pins the Syndicate Ed25519 release key, verifies `SHA256SUMS.sig`, verifies the selected x64/arm64 archive, rejects unsafe archive members, installs rootlessly under `~/.local/share/syndicate`, and keeps state under `~/.local/state/syndicate`.

A convenience copy of the reviewed installer and public key lives on `main`; immutable versioned release assets are the authoritative install path.

## Security boundary

The installer does not install or authenticate coding-agent CLIs, create an OS account, invoke `sudo`, alter a firewall, or upload provider credentials. Terminal input is code execution as the Syndicate OS user. Run it only under a dedicated unprivileged account whose repository and credential access you intend to grant.

Release archives include an SPDX SBOM, release metadata containing the exact private-source commit SHA, third-party notices, checksums, and an Ed25519 signature.