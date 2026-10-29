# NInfer Windows Manager

**Qwen on Windows, with simple PowerShell controls.**

Install NInfer, download the model, and start your local API from one manager. Docker Desktop provides the GPU runtime. Downloads and manager files stay in a single private `.ninfer` folder. Docker keeps its own images and TLS storage.

## Get started

You need Windows 11, PowerShell 7.2+, Git, Docker Desktop with WSL2/Linux containers, and an NVIDIA driver. This build targets the **RTX 5090 with 32 GB VRAM**; 64 GB system RAM is recommended. Allow at least 60 GB free for the first installation.

```powershell
git clone https://github.com/joelfourhman/ninfer_windows_manager.git
cd ninfer_windows_manager
.\ninfer-manager.cmd
```

Choose **1 — Start / Install**.

The first installation downloads about 22 GiB and builds NInfer. Interrupted downloads resume and the model is verified before use. Later starts reuse the installed files.

## Everyday use

The menu handles the usual controls. Commands work too:

| Task | Command |
|---|---|
| Start | `.\ninfer-manager.cmd -Action Start` |
| Stop | `.\ninfer-manager.cmd -Action Stop` |
| Restart | `.\ninfer-manager.cmd -Action Restart` |
| Status | `.\ninfer-manager.cmd -Action Status` |
| Logs | `.\ninfer-manager.cmd -Action Logs` |
| Run checks | `.\ninfer-manager.cmd -Action SelfTest` |

Docker Desktop must be running. Containers restart with Docker unless you deliberately stopped them.

## Connect a client

| Setting | Value |
|---|---|
| API base URL | `http://127.0.0.1:8080/v1` |
| Model | `qwen3.8-27b` |
| Context window | **262,144 tokens** |
| Default response budget | **8,192 tokens** |
| Authentication | API key |

Copy your key without printing it:

```powershell
.\ninfer-manager.cmd -Action CopyKey
```

Use a client that supports the OpenAI-compatible Chat Completions API. Your client controls compaction; a **75% threshold** leaves roughly 64K tokens of working room before the full context window.

## Optional HTTPS

Use an IPv4 address assigned to your PC:

```powershell
.\ninfer-manager.cmd -Action EnableHttps -Address 192.168.50.115
```

Your encrypted API will be `https://192.168.50.115:8443/v1`. The manager keeps the same model and API keys.

The public certificate is saved to `.ninfer/root-ca.crt`. Trust that certificate on connecting devices. For a DNS name, add `-ServerName qwen.home.arpa` and point that name at your PC.

To return to local access only:

```powershell
.\ninfer-manager.cmd -Action DisableHttps
```

## Keys

Create a separate key for another device:

```powershell
.\ninfer-manager.cmd -Action NewKey -Name laptop
.\ninfer-manager.cmd -Action Keys
```

The new key is shown once. You can copy an existing key with `-Action CopyKey -KeyId laptop-XXXXXXXX`, or revoke it with `-Action RevokeKey -KeyId laptop-XXXXXXXX`. Use the ID returned by the manager.

Keys are protected by your Windows account. Access changes reload Caddy without restarting the model.

## Your files

The project is one script, one launcher, and this README. Settings, keys, model files, downloads, and backups live under `.ninfer`, which is excluded from Git. Keep that folder private and retain it when updating the manager.

A previous deployment is kept for recovery when available:

```powershell
.\ninfer-manager.cmd -Action Rollback
```

The manager uses a pinned [upstream NInfer](https://github.com/Neroued/ninfer) build with NVFP4 weights, K8V4 context storage, MTP5, and one active inference lane.