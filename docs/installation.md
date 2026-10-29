# Installation

## Supported machine

The tested target is Windows 11 x64, an RTX 5090 with 32GB VRAM, and 64GB system RAM. The initial qwen profile is text-only, one active inference lane, NVFP4 weights, K8V4 context storage, MTP5, and an 8GiB host context reserve. Vision and DFlash2 are not enabled by this profile.

Allow 60GiB of free workspace disk space and additional Docker build cache. A v2-to-v3 migration temporarily requires a second model-sized file. An already-v3 official artifact is reused without modification. Docker data may reside on a different drive; verify its free space too.

## Prepare Windows once

Install Git before cloning. Install PowerShell 7.2+ and Docker Desktop from their official sources, or use:

```powershell
winget install --id Git.Git --exact --source winget
winget install --id Microsoft.PowerShell --exact --source winget
winget install --id Docker.DockerDesktop --exact --source winget
```

Enable WSL2 using the supported Windows setup flow (`wsl --install` from an Administrator terminal if required), reboot when requested, then start Docker Desktop and select Linux containers with WSL2 integration. Install a current NVIDIA Windows driver with support for the pinned CUDA runtime. Do not install a Linux GPU driver inside WSL.

The launcher checks PowerShell availability. The manager checks Docker, Compose, the GPU, RAM, and disk before large downloads. Missing prerequisites produce an actionable error; the manager does not change global execution policy, Windows features, or WSL memory limits silently.

## First installation

```powershell
git clone https://github.com/joelfourhman/ninfer_windows_manager.git
cd ninfer_windows_manager
.\ninfer-manager.cmd -Action Install -NonInteractive
```

The manager uses `deployment/runtime.lock.json` for the upstream commit, Linux amd64 base-image digests, and exact model revision/size/SHA-256. CUDA compilation happens in Docker. The host does not need CUDA, CMake, Visual Studio, or Python for inference installation.

The first build is intentionally reproducible at the source/image identity level. Ubuntu package repositories are not snapshot-pinned, so this is not a claim of bit-for-bit reproducible images. Release binaries are built locally; a published prebuilt manager image is not assumed.

Expected completion:

```text
PASS authenticated model discovery and inference.
NInfer Windows Manager | upstream ... | Hermes qwen
Local API: http://127.0.0.1:8080/v1 (API key required)
```

After enabling HTTPS, use `ExportHermes` to add Qwen to your existing default Hermes profile. ChatGPT remains the saved default. Use `CreateKey` for another client/device. See [keys](api-keys.md).

## Recovery and retries

- Re-run Install after a prerequisite reboot or network interruption.
- Partial model downloads remain as `.partial`; curl resumes them.
- A completed model must pass exact size and SHA-256 validation before use.
- Existing source is checked against its expected Git remote and must have no local edits.
- A failed source build leaves the current deployment available.
- Run `Start` for an installed stack; use `Repair` to rerun installation checks and rebuild missing components.

Docker Desktop must be running after Windows login for its restart policies to work. A reboot does not make Docker Desktop a pre-login Windows service. The manager leaves WSL/Docker resource limits untouched; increase a restrictive VM limit explicitly if startup reports insufficient host memory.
