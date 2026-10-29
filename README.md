# NInfer Windows Manager

Run **Qwen3.8-27B locally on an RTX 5090**, with upstream [NInfer](https://github.com/Neroued/ninfer), Qwen as an optional long-context model in Hermes, and authenticated HTTPS for trusted LAN or private-VPN clients.

The PowerShell manager downloads and verifies the model, builds a pinned Linux runtime inside Docker Desktop, starts inference, and manages client API keys. Your original NInfer-Ext deployment remains available for rollback.

## Clone and run

Prerequisites: Windows 11 x64, PowerShell 7.2+, Git, Docker Desktop with WSL2/Linux containers, an RTX 5090 with a working NVIDIA driver, 64GB RAM recommended, and at least 60GiB free plus Docker build-cache space. See [installation](docs/installation.md) for first-time setup and reboot recovery.

```powershell
git clone https://github.com/joelfourhman/ninfer_windows_manager.git
cd ninfer_windows_manager
.\ninfer-manager.cmd
```

Choose **Install / Start**. The first run downloads about 22GiB of model weights and builds CUDA code. Interrupted downloads resume; verified existing weights and images are reused. There is no Python environment to configure on Windows for the server.

For automation:

```powershell
.\ninfer-manager.cmd -Action Install -NonInteractive
.\ninfer-manager.cmd -Action Status
```

Success includes `PASS authenticated model discovery and inference`. The local endpoint is `http://127.0.0.1:8080/v1`; it requires an API key. Installation alone does not open a LAN port.

## Connect Hermes

Keep ChatGPT as your default Hermes model and add Qwen to the same profile. Enable HTTPS first, then run:

```powershell
.\ninfer-manager.cmd -Action ExportHermes -ClientName qwen
```

The manager backs up your existing settings, adds **Qwen (NInfer)** to the model picker, and stores a dedicated API key and provider-specific certificate trust. Your ChatGPT default and conversations are preserved. No separate profile is created.

Start Hermes normally for ChatGPT. Select Qwen from Desktop's model button, or launch a Qwen terminal session:

```powershell
hermes chat --provider qwen --model qwen3.8-27b
```

The project launcher `.\hermes-qwen.cmd` uses the same default profile. Qwen has a **262,144-token total window**, starts compaction at **75% of its available input budget**, and uses an **8,192-token default output budget**. ChatGPT keeps its default compaction policy; there is no shared absolute token cap. Follow [the Hermes guide](docs/hermes-qwen.md) for switching, verification, and compaction behavior.

## Encrypted access from another device

Use your server's actual LAN address and the smallest trusted IP/subnet:

```powershell
.\ninfer-manager.cmd -Action EnableLan -LanAddress 192.168.50.115 -TrustedRemoteAddress 192.168.50.0/24
```

After installing Hermes on the client, configure its own key and public certificate.

Windows requests Administrator approval for a scoped firewall rule. The HTTPS endpoint is `https://192.168.50.115:8443/v1`. Install/trust the exported public CA certificate on the client, or configure that client's certificate bundle. Each client needs its own API key. **Do not disable certificate verification.** See [network and HTTPS](docs/network-and-https.md).

## Daily commands

| Task | Command arguments after `.\ninfer-manager.cmd` |
|---|---|
| Start / stop | `-Action Start` / `-Action Stop` |
| Inspect / diagnose | `-Action Status` / `-Action Diagnostics` |
| Follow engine and gateway logs | `-Action Logs` |
| List client key metadata | `-Action ListKeys` |
| Create a key, shown once | `-Action CreateKey -ClientName workstation` |
| Revoke a key | `-Action RevokeKey -KeyId <id>` |
| Benchmark actual token counts | `-Action Benchmark` |
| Restore preserved NInfer-Ext | `-Action Rollback` |

## Documentation

- [Installation and prerequisites](docs/installation.md)
- [Migration and rollback](docs/migration.md)
- [Hermes model switching and compaction](docs/hermes-qwen.md)
- [LAN/private VPN and HTTPS](docs/network-and-https.md)
- [API key lifecycle and secret storage](docs/api-keys.md)
- [Operations, updates, backups, and removal](docs/operations.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Validation and measured limits](docs/validation.md)
- [Code review and recovery checks](docs/review.md)

Runtime state, secrets, model weights, and Hermes configuration are excluded from Git. This is a trusted single-owner service; separate device keys do not provide multi-tenant isolation. The manager serves inference; Hermes supplies tools and conversation management.
