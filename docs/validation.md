# Validation

## Run the checks

The HTTP-boundary tests use only Python's standard library and a local synthetic backend:

```powershell
python -m unittest discover -s tests -v
```

They cover missing/wrong/expired/revoked keys, immediate atomic registry updates, authentication failure, output and request limits, credential replacement at the backend boundary, unsupported routes, browser-origin restrictions, and incremental SSE forwarding. They require local loopback sockets; run outside a sandbox that blocks them.

Run `pwsh -NoProfile -File tests/manager.ps1` and `pwsh -NoProfile -File tests/recovery.ps1`, or use `-Action SelfTest` on Windows. The recovery checks simulate failed Hermes setup with existing/missing files, sticky profiles, access restriction before key writes, distinct gateway image identities, failed builds, and recovery of the previously running deployment. They do not replace a GPU install test.

```powershell
.\ninfer-manager.cmd -Action ValidateQwen -BenchmarkContexts 2048,32768,131000,248000
```

## Recorded machine

Windows 11 Pro; Ryzen 9 9950X3D; 64GB RAM; RTX 5090 32GB; driver 621.01. Upstream source is pinned in `deployment/runtime.lock.json`. The qwen profile uses NVFP4 weights, text-only MTP5, K8V4, one active lane, 8GiB host context, and a 262,144-token total limit.

Initial upstream startup reported an estimated 351,272-token KV capacity. That estimate is not an independent admission or quality guarantee.

On 2026-10-29, through the authenticated local proxy, four uncached prompts each generated 256 tokens:

| Actual input tokens | End-to-end seconds |
|---|---:|
| 2,108 | 1.83 |
| 32,829 | 4.59 |
| 131,060 | 22.29 |
| 248,062 | 61.95 |
| 260,061 | 65.80 |

These are one run per context, greedy decoding with thinking off. They establish admission/generation for this profile, not a statistically controlled speedup over NInfer-Ext. Model/system templates differ from the old benchmark, so those times must not be presented as a matched performance comparison.

The 260,061-token input plus 256-token output completed within the 262,144 total window on the restored renamed deployment. Ordinary Hermes sessions compact much earlier. The input-ceiling recommendation and Qwen-only 75% trigger preserve additional working room.

A second 248,055-token input was admitted with an 8,192-token output allowance and generated 1,046 tokens before its natural stop, in 71.92s. This validates that allowance and actual continuation, not a forced full 8K-token output. It measured about 63.5s TTFT and 126 tokens/s decode for that request.

## Release acceptance

Record separate evidence for: a clean first install, repeat install, key lifecycle, valid HTTPS with certificate verification, the firewall source restriction from a second device, real Hermes summary/continuation across multiple compactions, restart/resume, and an actual rollback/return-to-upstream cycle.

The real Hermes test uses installed Hermes v0.22.5, revision `bf0203a794a07aac3ff764972ab9087baa4e4f4e`. `tools/validate_hermes.py` exercises its actual ContextCompressor against local inference, checks the current Qwen-only 75% threshold, and reloads saved synthetic transcripts between two compactions.

The unassisted run failed: a large repetitive transcript lost `SOURCE-TIDAL-ALPHA` and `UNRESOLVED-SALINITY-OMEGA`, while retaining the URL and ledger path. Hermes bounds/elides summary input before sending it to the model. This is a continuity limitation, not a capacity failure. The failed result is retained in runtime logs.

With an explicit persistent task ledger restored outside the compacted transcript, both compactions and the final model recall passed. Summary times were 15.22s and 18.95s in that run. The profile's continuity instructions require a durable ledger and concise persistent identifier index. This test does not prove automatic ledger maintenance for arbitrary tasks, nor is it a full overnight task evaluation.

Verified HTTPS on a loopback-only Caddy test listener passed certificate-chain/hostname validation, authenticated discovery/inference, SSE, and a strict function-tool call. Missing/wrong keys returned 401, and an untrusted CA failed verification. Windows Schannel curl could not establish private-CA revocation status; the Python SSL explicit-CA path passed without disabling certificate verification.

The actual Hermes CLI completed a normal request and, in a new process, resumed the saved session and recovered its prior answer. The HTTP boundary suite passes 13 tests, including propagation of client disconnect to the upstream stream. PowerShell tests pass key isolation/revocation, secret-free Compose metadata, private backend networking, local-only default publication, and selected-address TLS generation. Live key replacement/revocation passed without restarting the model; scans found no manager/backend key values in Docker inspection metadata or operational logs.

The manager's Install action was rerun from the renamed `ninfer_windows_manager` checkout, reusing the verified existing v3 model and pinned image, and passed discovery/inference after recreating its bind paths. This is a fresh checkout/repeat-install test on a prepared host, not a clean Windows VM or a fresh 22GiB network-download test.

`VerifyRollback` passed inference with the exact preserved legacy image and original model/runtime options on an unpublished private network, then restored upstream successfully. The original container remained untouched. Its pre-existing external HTTP listener was intentionally not reopened for this test.

After explicit scope approval, HTTPS is active at `https://192.168.50.115:8443/v1`. The owned Windows firewall rule permits TCP 8443 only on local address 192.168.50.115 from 192.168.50.0/24, across Windows network profiles. Same-host tests through that LAN address passed certificate-chain/hostname validation, authenticated inference, SSE, strict tool calls, missing/wrong-key rejection, and untrusted-CA rejection. An initial IP-based handshake failure was fixed by configuring Caddy default_sni; this supports clients that omit SNI for IP literals. A second physical device and outside-subnet source filtering have not been exercised. An overnight workload has not been run.

The repository includes a digest-pinned GitHub Actions workflow for Windows and Ubuntu contract tests on Python 3.11. Each push runs the same HTTP and PowerShell checks on both operating systems; inspect the Actions result for the specific published revision. The server and gateway are built locally from pinned source/base images; no published prebuilt manager image is claimed.

The final run report must distinguish completed checks from any outstanding LAN authorization or second-device checks. A passing model benchmark alone must not be described as a passing long-running workflow. A same-host TLS test must not be described as a second-device firewall test.

The single default Hermes profile also passed real ChatGPT and Qwen CLI requests. Environment-only CA settings initially failed with the Windows platform verifier in the installed Hermes version. Adding a URL-matched provider ssl_ca_cert with ssl_verify enabled fixed the primary/auxiliary route configuration without importing a CA into the Windows trust store. The manager now adds that provider entry to the default home without changing its saved model.

## Single-profile model selection

ChatGPT remains the saved default. Qwen is a provider in the same default profile, uses HTTPS with its own key and CA trust, and applies a 75% model-specific compaction rule. The default global compaction settings were compared with the saved original; the only added threshold is for Qwen. The earlier 180K absolute-cap results above describe that earlier run, not the current trigger. Current acceptance is recorded in `logs/qwen-default-compaction.json`.

## Reviewed deployment

The local suite passes 15 HTTP-boundary tests, PowerShell runtime/key tests, and isolated Hermes/recovery regressions. The reviewed gateway also passed live HTTPS discovery, inference, SSE, forced tool calls, missing/wrong-key rejection, and rejection of an untrusted CA. The GPU engine remained running during the gateway update. Raw machine logs and credentials remain private under ignored runtime directories.

The most recent per-model compaction run used the actual shared default home, selected Qwen explicitly, verified its 190,464-token trigger with an 8,192-token output reservation, and completed two summaries with transcript reload and final model recall. Exact identifiers were recovered from the persistent synthetic ledger; the first raw summary omitted two identifiers. This is a ledger-backed acceptance test, not a claim that summaries alone retain every detail. See [review notes](review.md) for corrected failure paths and remaining operational limits.
