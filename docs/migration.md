# Migration and rollback

The GitHub repository is `joelfourhman/ninfer_windows_manager`. The manager uses upstream `Neroued/ninfer`; NInfer-Ext is retained only as an existing-installation rollback target.

## Preserved resources

New state lives under `config/manager/`. Legacy `config/settings.json`, `config/deployment.json`, `config/secrets.json`, the `source/ninfer-ext` checkout, old Docker images, and the `ninfer-ext` container are retained. The original model is verified and never overwritten. A v2 model is converted into a separate `.v3.ninfer`; an already-v3 model is reused.

Before replacing a legacy manager script, retain a private copy of the script, launcher, README, settings, deployment state, and secrets. This installation's pre-change copy is under `config/migration-backup-*/`. Existing uncommitted edits are included in that copy. Never upload that directory; it contains credentials.

Install builds and checks new components before stopping a running owned legacy container. A failed replacement restores the previously running legacy container, including when an older upstream snapshot still exists. If legacy was stopped, a failed upstream replacement restores the prior upstream runtime instead. Subsequent runtime replacements keep snapshots of the previous upstream Compose/TOML configuration. Gateway images are named from their source, Dockerfile, and pinned Python identity, so a new build cannot replace the gateway image referenced by a snapshot. Keep those images until the replacement has been accepted. Client-key registries are deliberately not rolled back.

## Return to NInfer-Ext

```powershell
.\ninfer-manager.cmd -Action Rollback
```

This stops the new stack and starts the existing owned `ninfer-ext` container. It uses its original model mount, API key, and network bindings, including any pre-existing plaintext LAN binding. New gateway credentials and HTTPS URLs do not apply to that legacy endpoint. Only use legacy LAN access on a network where its original configuration is acceptable.

To return to upstream:

```powershell
.\ninfer-manager.cmd -Action Start
```

The new manager stops an owned running legacy container before occupying the GPU. It refuses to adopt containers with another owner label. If the preserved container has been deleted, recreate it using the backed-up legacy manager and settings; the new manager does not pretend a missing image/container is recoverable.

`-Action VerifyRollback` temporarily stops upstream, starts an unpublished private-network probe using the exact preserved legacy image/model/runtime options, checks inference, removes the probe, and restores upstream. This tests the rollback components without reopening the legacy plaintext LAN listener or changing the original container. It temporarily interrupts inference and does not claim to test the original container's external network route.

## Local directory rename

If Windows allows it, close programs using the old directory and rename it from its parent, then reopen the new path in Codex. Runtime Compose files contain absolute bind paths; run `Start` from the new folder to regenerate them. The Hermes certificate is copied into the default home, so moving the manager does not change its path. Update the provider URL only if the server address changes.

When Windows holds the original folder open, a side-by-side renamed checkout is safer: leave the old directory as the legacy rollback installation, copy the new working files to `ninfer_windows_manager`, and regenerate runtime paths there. Do not remove the old model folder while the preserved legacy container mounts it. A same-volume model hard link may reuse immutable model bytes without another 22GiB copy; do not modify either linked file in place.
