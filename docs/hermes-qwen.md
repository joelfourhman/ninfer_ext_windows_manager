# Qwen in Hermes

Use one Hermes profile. ChatGPT remains the default destination; Qwen is an optional model in that profile's model picker. Both models use your existing conversations, tools, memory, and workspace settings.

## Everyday use

Start Hermes normally:

```powershell
hermes chat
```

This uses your configured ChatGPT subscription route. In Hermes Desktop, use the model button above the message box and choose **Qwen (NInfer) → qwen3.8-27b** when you want local inference. Choose **ChatGPT or Codex Subscription → gpt-6.1-sol** to return to ChatGPT. The composer remembers its last choice on this device; the saved default stays ChatGPT.

For a terminal session using Qwen:

```powershell
hermes chat --provider qwen --model qwen3.8-27b
```

The project launcher `hermes-qwen.cmd` runs the same command against the default profile. There is no separate Qwen profile to select. Model switches are session choices; `model.persist_switch_by_default: false` protects the saved default.

## Add the connection

Install Hermes and complete its usual setup first. Enable HTTPS in the manager, then run:

```powershell
.\ninfer-manager.cmd -Action ExportHermes -ClientName qwen
```

The manager backs up the existing configuration, environment, key ID, and public certificate, then adds `providers.qwen` to `%LOCALAPPDATA%\hermes\config.yaml`. It stores a dedicated, revocable key as `HERMES_CUSTOM_QWEN_API_KEY` in that home's protected `.env`. It copies the public certificate to `certs/ninfer-root-ca.crt` and enables certificate verification for the Qwen provider. It does not change `model.default`, your ChatGPT sign-in, or SOUL.md.

There are no global `OPENAI_BASE_URL`, `SSL_CERT_FILE`, or `REQUESTS_CA_BUNDLE` overrides. Certificate trust is scoped to NInfer, so other providers and dependency downloads keep their usual trust settings. Never disable certificate verification.

For another device, install Hermes there and configure its own default home with its own client key and the public CA certificate. Certificate paths are machine-specific. Never copy a CA private key or share a device's API key. See [network access](network-and-https.md) and [key management](api-keys.md).

The command explicitly targets the default home even if another profile was selected earlier. A failed setup restores the previous files and revokes its new key. Re-running setup keeps older keys valid until you explicitly revoke their IDs; see [key management](api-keys.md).

## Context and compaction

| Budget | Qwen setting |
|---|---:|
| Input plus reasoning/output limit | 262,144 tokens |
| Compaction trigger | 75% of the available input budget |
| Space remaining at that point | At least 65,536 tokens |
| Normal output default | 8,192 tokens |
| Maximum explicit output request | 16,384 tokens |
| Suggested input ceiling | 229,376 tokens |

The provider and its model catalog declare Qwen's 262,144-token window. `compression.model_thresholds.qwen: 0.75` applies only when Qwen is selected. Hermes subtracts an explicit output reservation before calculating the percentage. With an 8,192-token reservation the trigger is 190,464 prompt tokens, leaving 71,680 tokens in the total window; without an explicit reservation it is 196,608, leaving 65,536. There is no shared absolute token cap.

ChatGPT retains the original default compaction policy. Switching models re-evaluates the threshold against the selected model's own context window. Compaction follows that active model through `auxiliary.compression.provider: main`, with an empty model override, so Qwen summaries use the same verified HTTPS route. Qwen defaults to fast responses through its own provider settings; this does not change ChatGPT. The server accepts one inference request at a time; Qwen chat and compaction share that GPU lane.

A single large tool result can still exceed the available window. Keep large documents on disk and retrieve sections. Maintain a task ledger and a concise source-identifier index in persistent memory; summaries alone do not preserve every detail. After compaction, reload the ledger before continuing.

## Verify

```powershell
hermes config get model
hermes config get providers.qwen
hermes config get compression.model_thresholds
hermes config get auxiliary.compression
```

The saved model should remain your ChatGPT model. Qwen should show HTTPS, context `262144`, its named key variable, and `ssl_verify: true`. Do not print `.env` or pass keys on a command line.

The manager's tests cover key isolation, output budgets, API routing, and configuration rollback. Live checks verify ChatGPT, Qwen over HTTPS, the per-model compaction rule, and real compaction with saved-transcript reload and ledger recovery. See [validation](validation.md) for measured limits. Large-context admission does not establish factual accuracy or guarantee unattended task completion.