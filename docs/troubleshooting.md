# Troubleshooting

| Symptom | Action |
|---|---|
| `pwsh` missing | Install PowerShell 7.2+, reopen the terminal, rerun the launcher. |
| Docker daemon unavailable | Start Docker Desktop, wait for readiness, verify Linux containers/WSL2 integration. |
| No GPU in Docker | Update the Windows NVIDIA driver and Docker/WSL; do not install a WSL Linux NVIDIA driver. |
| Missing prerequisite | Follow `installation.md`; reboot if required, then rerun Install. |
| Model checksum mismatch | Keep the file for diagnosis; compare exact lock metadata before replacing it. Never skip verification. |
| v3 model conversion says v2 expected | Already-v3 official artifacts must be reused; current manager detects the header before conversion. |
| Upstream process exits during startup | Run Logs. Check resource allocation and pinned-runtime configuration. Old setup is retained. |
| GPU memory is tight | Close other GPU workloads. Keep vision off and one lane; inspect actual capacity before changing KV settings. |
| A long request starts slowly | Inspect prefill/TTFT separately from decode; a fresh 248K prompt can take around a minute on this machine. |
| Another manager action is running | Wait for it to complete; the lock prevents conflicting state mutations. |
| HTTP 401 | Use that client's new-manager key; check expiry/revocation. Legacy keys do not apply. |
| HTTP 429 | Too many concurrent proxy requests; retry after existing inference/compaction finishes. |
| Output-limit error | Explicit generation requests must be at most 16,384 tokens. Default is 8,192. |
| Certificate verification failed | Check hostname/IP, public CA trust, and client certificate-bundle paths. Never disable verification. |
| Windows curl reports unknown revocation status for the private CA | Use the Python/Hermes explicit CA-bundle workflow. Schannel may request revocation metadata a private Caddy CA does not publish; certificate-chain and hostname checks must remain enabled. |
| LAN connection refused | Check the selected adapter/IP, Caddy, HTTPS port, and successful Administrator firewall action. |
| LAN works locally but not remotely | Test from a second device; inspect VPN routes, subnet scope, Windows firewall, and router client isolation. |
| Hermes cannot start | Use `hermes doctor`; repair a missing dependency environment with `hermes pm repair`. |
| Hermes summary uses a cloud model | Select Qwen in the same default profile; confirm `auxiliary.compression.provider: main`, empty model/base-URL overrides, and the HTTPS `providers.qwen` entry. |
| Hermes compaction times out | Inspect prefill progress and the active model route. The auxiliary request timeout defaults to 120 seconds; change it deliberately if needed, since it is shared by both models. |
| Failed Hermes setup | The manager restores config, environment, key ID, and public CA and revokes its new key. Read the displayed backup path if restoration needs manual help. |
| Need old behavior immediately | Run Rollback; use the old endpoint/key. Read the legacy-network caveat in migration.md. |

Diagnostics shows operational logs, runtime identity, and inference health. Keep configuration files, `.env`, certificate private keys, and full conversation transcripts out of public issue reports.
