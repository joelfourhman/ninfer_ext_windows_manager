# NInfer-Ext Windows Manager

A PowerShell manager for installing and operating
[`giveen/ninfer-ext`](https://github.com/giveen/ninfer-ext) on Windows 11 with
Docker Desktop, WSL2, and an NVIDIA GeForce RTX 5090.

The manager downloads and verifies the configured model, checks GPU passthrough,
builds an immutable Docker image from a pinned upstream commit, starts an
authenticated local API, validates inference, and supports updates with rollback.

## Requirements

- 64-bit Windows 11, build 22000 or newer
- PowerShell 7 (`pwsh`)
- Git
- WSL2
- Docker Desktop using Linux containers
- NVIDIA GeForce RTX 5090 with working Docker GPU passthrough
- At least 48 GiB system RAM; 64 GiB or more is recommended
- At least 55 GiB free disk space for the model, source, image, and build cache
- Internet access to GitHub and Hugging Face during installation

Install PowerShell 7 if needed:

```powershell
winget install --id Microsoft.PowerShell --exact
```

## Run the manager

The easiest option is the launcher, which applies execution-policy bypass only
to the child PowerShell process used for this run:

```powershell
.\ninfer-manager.cmd
```

Select **Install / Start** from the menu. The first installation downloads a
large model and compiles the CUDA application, so it can take a while.

### Run the PowerShell script directly

If Windows blocks `.ps1` files, set the execution policy for the **current
PowerShell process only**, then run the script:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\ninfer-manager.ps1
```

`-Scope Process` is temporary: it affects only the current PowerShell window and
is discarded when that process exits. It does not change the policy for the
current user or the computer. The `Set-ExecutionPolicy` command only changes the
current process policy; it does not launch the manager by itself.

You can also apply the same temporary policy and launch the script in one command:

```powershell
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\ninfer-manager.ps1
```

## Non-interactive commands

Pass an action through the CMD launcher when scripting:

```powershell
.\ninfer-manager.cmd -Action Install -NonInteractive
.\ninfer-manager.cmd -Action Status -NonInteractive
.\ninfer-manager.cmd -Action Diagnostics -NonInteractive
.\ninfer-manager.cmd -Action Stop -NonInteractive
.\ninfer-manager.cmd -Action Start -NonInteractive
```

Supported actions include `Install`, `Start`, `Stop`, `Restart`, `Status`,
`CheckUpdates`, `Update`, `Rebuild`, `Logs`, `Diagnostics`, `Repair`,
`ModelSettings`, `PerformanceSettings`, `NetworkSettings`, `ResetDefaults`,
`ShowKey`, `RotateKey`, `Firewall`, `StressTest`, `SelfTest`, and `Uninstall`.

## Default deployment

The default profile uses:

- Qwen3.8 27B NVFP4 model artifact with pinned revision, size, and SHA-256
- 262,144-token configured context
- FP8 KV cache with KV streaming and dynamically sized host KV memory
- One concurrent request
- Five-token fixed MTP drafting with LM-head drafting
- Local-only binding at `http://127.0.0.1:8080/v1`
- Generated bearer-token authentication
- Docker restart policy `unless-stopped`

Use **Show / Rotate Key** to display or replace the API key. Treat that key as a
secret. LAN access is disabled by default and requires an explicit network and
restricted firewall configuration.

## Files created at runtime

Runtime data stays beside the manager and is intentionally excluded from Git:

- `config/` — settings, deployment state, and the API key
- `models/` — downloaded model artifacts and checksum markers
- `source/` — the managed upstream source checkout
- `logs/` — manager logs
- `temp/` — generated build files

Docker images and the `ninfer-ext` container remain managed by Docker Desktop.
The one-time GPU check may retain an `nvidia/cuda` base image for reuse.

## Troubleshooting

Run diagnostics from the menu or directly:

```powershell
.\ninfer-manager.cmd -Action Diagnostics -NonInteractive
```

Useful Docker checks:

```powershell
docker ps --filter name=ninfer-ext
docker logs --tail 100 ninfer-ext
docker system df
```

Do not commit anything from `config/`: `config/secrets.json` contains the bearer
token that grants access to the inference server.
