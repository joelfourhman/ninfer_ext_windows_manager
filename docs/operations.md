# Operations

## Start, stop, and restart

```powershell
.\ninfer-manager.cmd -Action Start
.\ninfer-manager.cmd -Action Status
.\ninfer-manager.cmd -Action Stop
.\ninfer-manager.cmd -Action Restart
```

Containers use `unless-stopped`. Docker Desktop must itself be running after Windows login. Stop is intentional and remains respected across Docker restarts. The manager serializes CLI mutations using a file lock. Avoid editing generated runtime files while it operates.

`SelfTest` runs the standard-library HTTP checks plus PowerShell runtime-generation, Hermes-setup, and recovery tests without using the GPU. The default menu exposes common actions. All actions are available through `-Action`; `-NonInteractive` avoids the menu. Setup does not send inference to a cloud provider.

## Updates

`CheckUpdates` reports upstream HEAD without applying it. `Update` installs the commit and image identities in the checked-in lock file. Updating to a new upstream revision is a maintainer task: change the lock, run the affected acceptance tests, then distribute the tested manager revision. Do not automatically deploy arbitrary HEAD at menu startup.

`Rebuild` rebuilds the pinned engine. `Repair` reruns the installation workflow, reusing verified components. Gateway builds use content-derived tags and retain earlier image identities for runtime recovery. New upstream runtime snapshots are stored privately under `config/manager/snapshots/`; keep previous images until the replacement is validated. See [migration](migration.md).

## Inspect and benchmark

```powershell
.\ninfer-manager.cmd -Action Diagnostics
.\ninfer-manager.cmd -Action Benchmark -BenchmarkContexts 2048,32768,131000,248000 -BenchmarkOutputTokens 256
```

Reports live under `logs/`. Requested context targets are approximate until the model reports actual token usage. Benchmarks use unique prompts to avoid cross-run prefix reuse. Long uncached prompts have substantial time-to-first-token; decode speed is a separate metric.

`-Action VerifyRollback` tests the preserved legacy components on an unpublished private network and restores upstream. It deliberately interrupts the new service during the check. See [migration](migration.md) for its scope.

`Status` shows configured context and any recorded validation report. It does not print API keys. Do not use `docker exec ... cat /run/manager/...` or share the configuration directory in a support bundle.

Engine configuration is fingerprinted in a container label, so changing a startup setting recreates the engine when Start is applied. Client-key registry updates are excluded from that fingerprint and take effect without a model restart. Detailed request JSONL is disabled by default; benchmark reports retain usage counts and timings rather than generated text/token IDs.

## Backup and restore

Back up the Git checkout, private `config/`, required model files, and Caddy's persistent Docker data volume. Keep secret backups encrypted and access-controlled. Conversation transcripts and memories belong to the selected Hermes data root and need their own backup.

Restoring API-key state can resurrect revoked keys; after disaster recovery, reconcile revocations before exposing the service. Routine engine rollback leaves the current registry intact. Restoring a different CA requires distributing the new public root to trusted clients.

## Remove the new stack

```powershell
.\ninfer-manager.cmd -Action Uninstall -Yes
```

This removes the owned Compose services/networks and requests removal of the owned firewall rule. It retains models, configuration, private certificates/volumes, Hermes configuration, legacy containers/images, and backups. Any permanent deletion of those is a separate deliberate action.
