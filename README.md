# makiopencodego

Maki provider plugins for the [OpenCode Go](https://opencode.ai/v2/docs/console/go/) gateway.

Maki posts every `opencode-go` model to `/chat/completions`, but the gateway
serves several models only on other routes and answers them there with
`ModelProtocolUnsupported`. A plugin cannot claim the `opencode-go` slug, so
this package registers one companion provider per wire format. Use
`opencode-go-<route>/<model>` where you would have used
`opencode-go/<model>`; everything else stays on the built-in provider.

| Slug | Route | Families |
| ---- | ----- | ------ |
| `opencode-go-chat` | `/chat/completions` | `deepseek-*`, `glm-*`, plus `minimax-m3.1-flash-free` |
| `opencode-go-responses` | `/responses` | `grok-*`, `gpt-*`, `muse-spark-*` |
| `opencode-go-gemini` | Gemini native | `gemini-*` |
| `opencode-go-anthropic` | `/v1/messages` | `claude-*`, `qwen*`, `minimax-*` except `minimax-m3.1-flash-free` |

Each slug lists its families live from the gateway catalogue, so a new
sibling (a future `grok-4.8`) appears without a package update. Ids outside
these families (`kimi-*`, `mimo-*`, `longcat-*`, `hy*`, `step-*`,
`beam-*`, `omen-alpha`, …) stay on the built-in `opencode-go` provider and
are hidden from the companions.

Beyond routing, the chat provider unlocks the full `reasoning_effort` ladder
(`minimal`–`max`, plus a working off) that the built-in catalog path cannot
express, and each provider filters the model picker to the families it
actually shapes so a chat model can never be posted to `/responses` by
mistake.
Pricing mirrors the Go usage table; where the gateway charges more above a
context threshold, the declared window sits at the threshold so compaction
keeps requests inside the cheap tier. Models with no published rate yet (a
new launch, or an id missing from models.dev) show no cost estimate until
their row is curated. The full rationale is documented in
`plugin/opencode_go.lua`.

Upstream issue: https://github.com/tontinton/maki/issues/1091

## Install

Add the package to `~/.config/maki/init.lua`:

```lua
maki.pack.add({
  { src = "https://github.com/eddiectc/makiopencodego", version = "main" },
})
```

Restart Maki (or run `/reload`) and approve the `net` + `env` permission
prompts. The four slugs then appear in the model picker and in `/model`.

## Auth

Set your key once:

```bash
export OPENCODE_API_KEY="..."
```

or store it per slug with `maki auth login` and pick the
`opencode-go-*` provider when prompted.

## Update

`/packupdate` pulls the latest `main`.

## Permissions

`net` + `env` only, with egress pinned to `opencode.ai`. The providers POST
to the gateway and read `OPENCODE_API_KEY` as a fallback when no stored
credentials resolve. Nothing is written or executed.

## Notes

- Requires maki 0.6.0 or newer.
- OpenCode Go requires a stable `x-opencode-session` header; the package
  generates one id per process and shares it across all four slugs.
- Model availability follows your Go plan; a model outside your tier fails
  at the gateway with its own error, not a routing error.
