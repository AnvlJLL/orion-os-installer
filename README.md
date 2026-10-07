# Orion-OS installer

One-line installers for Orion-OS. These scripts contain no Orion code. They get your computer ready (Git, Node, Python via uv, Claude Code) and then download Orion-OS. The download only works if you've accepted an invitation to the private repository.

> **Pre-release (`v0.1.0-rc1`).** It hasn't been verified on clean machines yet. Use it only if you were asked to test it.

You can read the scripts before running them: [install.ps1](install.ps1) · [install.sh](install.sh).

**Windows** (normal PowerShell):

```powershell
irm https://raw.githubusercontent.com/AnvlJLL/orion-os-installer/v0.1.0-rc1/install.ps1 | iex
```

**macOS** (Terminal):

```bash
curl -fsSL https://raw.githubusercontent.com/AnvlJLL/orion-os-installer/v0.1.0-rc1/install.sh | bash
```

To check your computer without changing anything, set `ORION_INSTALLER_CHECK=1` first:
- Windows: `$env:ORION_INSTALLER_CHECK='1'`
- macOS: `export ORION_INSTALLER_CHECK=1`

Always use a tagged URL (`/v…/`), never `main`.
