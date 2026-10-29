# Code review and validation

The reviewed version keeps ChatGPT as the saved Hermes default and exposes Qwen as a model in that same profile. Qwen uses HTTPS, a separate device key, a 262,144-token window, and a 75% model-specific compaction threshold.

## Issues corrected

| Finding | Correction | Evidence |
|---|---|---|
| Failed Hermes setup could retain newly created files or overwrite its previous CA | Snapshot config, environment, key ID, and certificate; restore existing files and remove new ones; revoke only the failed key | `tests/recovery.ps1` exercises existing and absent files and checks the original key remains valid |
| A sticky named profile could redirect setup away from the intended home | Every config mutation explicitly uses `--profile default` under the selected home | Recovery tests inspect the invoked target and verify the caller environment is restored |
| Rebuilding a mutable gateway tag could invalidate a runtime snapshot | Derive its image name from gateway source, Dockerfile, and pinned Python identity; build before interrupting services | Recovery tests prove source changes produce a distinct image name |
| A stale upstream snapshot could prevent recovery of a running legacy deployment | Restore whichever deployment was running before the attempt; leave key revocations untouched | Recovery tests cover running/stopped legacy state and a failed build |
| The policy endpoint returned before validating HTTP body framing | Validate framing first and reject non-POST bodies | HTTP tests cover invalid transfer encoding, GET bodies, authentication, and credential isolation |
| Failed LAN startup could retain the new saved address and firewall scope | Restore previous settings and the prior owned scope, or remove the newly added rule; DisableLan removes its rule before runtime changes | Recovery tests cover previously enabled and disabled LAN state |
| Menu restart did not stop existing services | Use the same stop/start sequence as the explicit Restart action | Reviewed action dispatch; runtime/key regression suite |

## Validation boundaries

The automated suite uses synthetic data and mock deployments for failure recovery. Live checks cover the real managed API, verified TLS, authentication, streaming, tool calls, and Qwen compaction. A second-device firewall test and an overnight task have not been completed. The large-context benchmark was retained from the same pinned engine/model/KV settings; the GPU binary was not rebuilt for these gateway/manager corrections.

This is a trusted single-owner service. Device keys provide revocation and attribution, not separate tenants. Docker administrators can read mounted secrets. Filesystem ACLs protect plaintext secrets; they do not encrypt them at rest. Keep private snapshots encrypted and reconcile revocations after disaster recovery. SSE cancellation is tested after output begins; immediate cancellation of GPU prefill is not guaranteed.
