-- OpenCode Go companion providers: one file, four slugs.
--
-- maki picks one wire format per models.dev provider, and models.dev marks
-- `opencode-go` as `@ai-sdk/openai-compatible`, so the built-in provider posts
-- every model to /chat/completions. The gateway serves several models only on
-- other routes and answers them on /chat/completions (and vice versa) with:
--
--   API error (400): {"type":"error","error":{"type":
--   "ModelProtocolUnsupported","message":"Model does not support this
--   protocol."}}
--
-- A plugin cannot claim the `opencode-go` slug (models.dev owns it), and one
-- slug per codec is mandatory (there is no per-model codec override), so this
-- file registers a companion provider per wire format. Multiple
-- `maki.provider.register` calls in one file are supported. Use
-- `opencode-go-<route>/<model>` where you would have used
-- `opencode-go/<model>`; everything else stays on the built-in provider.
--
--   opencode-go-chat      codec "openai"           zen /chat/completions
--   opencode-go-responses codec "openai-responses" zen /responses
--   opencode-go-gemini    codec "google"           inference Gemini route
--   opencode-go-anthropic codec "anthropic"        inference /v1/messages
--
-- Upstream issue: https://github.com/tontinton/maki/issues/1091
-- Endpoint table: https://opencode.ai/v2/docs/console/go/#endpoints

----------------------------------------------------------------------------
-- Shared: session id, auth, helpers
----------------------------------------------------------------------------

-- OpenCode Go requires a stable `x-opencode-session` on every request, but
-- maki writes it only for its built-in `opencode`/`opencode-go` slugs. A
-- plugin slug is not part of that family, so these providers add the header
-- themselves. The auth hook is the only hook whose headers reach a request
-- (the responses codec ignores the `openai.session_id` option); maki gives
-- it no session id and runs it once per plugin load, so this is one id per
-- process, not per conversation. One id is shared across all four slugs in
-- this file — still "one stable value per process", with better cache
-- affinity than a separate id per provider.
local SESSION_HEADER = "x-opencode-session"
local SESSION_ID = string.format("maki-%d-%d", os.time(), math.random(0, 2147483647))

-- Base URLs: chat and responses share the zen origin; the Gemini route lives
-- only under the `inference` origin (the same `:streamGenerateContent` path
-- on `zen` answers 404 from the website router). The anthropic codec POSTs
-- to `origin(base_url) .. "/v1/messages"`, where `origin()` strips a
-- trailing `/v1/messages`, so the anthropic base declares no `/v1` suffix.
local ZEN_BASE_URL = "https://opencode.ai/zen/go/v1"
local GEMINI_BASE_URL = "https://opencode.ai/inference/go/v1"
local ANTHROPIC_BASE_URL = "https://opencode.ai/inference/go/anthropic"

local function pricing(p)
  return { input = p[1], output = p[2], cache_write = p[3], cache_read = p[4] }
end

local function has_header(headers, name)
  for k in pairs(headers) do
    if k:lower() == name then
      return true
    end
  end
  return false
end

-- Removes a codec-resolved key header and returns its value, so the key can
-- be re-sent in the form the gateway expects. Returns nil when maki resolved
-- no credentials for this slug. `name` must be lowercase.
local function take_header(headers, name)
  for k, v in pairs(headers) do
    if k:lower() == name then
      headers[k] = nil
      return v
    end
  end
  return nil
end

-- Builds the auth closure shared by all four providers. `lift` is the
-- codec-resolved key header to convert to bearer (lowercase), or nil for
-- passthrough: the openai/openai-responses codecs already resolve
-- `api_key_env` (and `maki auth login` keys) into `Authorization`, while the
-- google codec resolves into `x-goog-api-key` and the anthropic codec into
-- `x-api-key`, and the Go gateway authenticates with a bearer token.
-- Keeps the resolved credentials and adds the session header. Omitting
-- `base_url` keeps the resolved origin.
local function make_auth(lift)
  return function(ctx)
    local headers = {}
    for k, v in pairs(ctx.headers or {}) do
      headers[k] = v
    end
    local lifted = nil
    if lift then
      lifted = take_header(headers, lift)
    end
    if not has_header(headers, "authorization") then
      local key = lifted
      if not key or key == "" then
        key = maki.uv.os_getenv("OPENCODE_API_KEY")
      end
      if key and key ~= "" then
        headers.Authorization = "Bearer " .. key
      end
    end
    headers[SESSION_HEADER] = SESSION_ID
    return { headers = headers }
  end
end

local auth_bearer = make_auth(nil)
local auth_google = make_auth("x-goog-api-key")
local auth_anthropic = make_auth("x-api-key")

-- Each provider pins the picker to the models it actually shapes; see the
-- per-slug comment at the `list_models` call site for what goes wrong
-- without the pin.
local function pin(rows)
  return function() return rows end
end

----------------------------------------------------------------------------
-- Chat: `opencode-go-chat` (codec "openai")
----------------------------------------------------------------------------
--
-- OpenCode Go chat-completions models that need the full reasoning-effort
-- ladder.
--
-- maki's built-in `opencode-go` provider is a models.dev catalog provider, so
-- every model it knows about is posted to /chat/completions through the
-- hardcoded `dialect::PREFER_HIGH` shape (`catalog.rs`). That dialect only
-- supports [Low, Medium, High] and omits the field entirely when thinking is
-- off, so `max`/`xhigh` snap down to `"high"` and `/thinking off` leaves
-- thinking on. models.dev declares these models with
-- `reasoning_options: [{type:"effort", values:["low","high","max"]}]`, and the
-- gateway accepts `reasoning_effort ∈
-- {none,minimal,low,medium,high,xhigh,max}`, but the catalog path can't express
-- that.
--
-- A plugin cannot claim the `opencode-go` slug (models.dev owns it), so this
-- companion provider points the chat-completions codec at the same gateway with
-- the `gpt-5-6` thinking dialect, whose supported set is
-- [Minimal, Low, Medium, High, XHigh, Max] and whose `off` value is `"none"`.
-- That passes the user's choice through unchanged and makes off actually
-- disable thinking. Use `opencode-go-chat/<model>` where you would have used
-- `opencode-go/<model>`.
--
-- The gateway also rejects a thinking request that has tool calls but no
-- `reasoning_content` on prior assistant messages ("The reasoning_content in
-- the thinking mode must be passed back to the API"). maki only back-fills
-- that in the bundled `deepseek` plugin, not on the catalog path, so
-- `build_body` pads it here too.
--
-- Upstream issues: https://github.com/tontinton/maki/issues/1091
--                  https://github.com/anomalyco/opencode/issues/48180

-- id, tier, context_window, max_output_tokens, vision,
-- pricing = { input, output, cache_write, cache_read } in USD per 1M tokens.
-- Values mirror models.dev.
local CHAT_MODELS = {
  { "deepseek-v4.1-flash", "medium", 1000000, 384000, true, { 0.15, 0.6, 0.0, 0.003 } },
  { "deepseek-v4-pro", "strong", 1000000, 384000, false, { 0.66, 1.98, 0.0, 0.022 } },
  { "glm-5.3-flash", "medium", 1000000, 131072, true, { 0.15, 0.5, 0.0, 0.003 } },
}

local chat_rows = {}
local chat_listed = {}
for i, m in ipairs(CHAT_MODELS) do
  local id, tier, context, out, vision, price = m[1], m[2], m[3], m[4], m[5], m[6]
  chat_rows[i] = {
    prefixes = { id },
    tier = tier,
    family = "generic",
    context_window = context,
    max_output_tokens = out,
    supports_vision = vision,
    -- Keeps the picker offering the full ladder even though the wire below is
    -- what decides which levels are actually meaningful.
    supports_thinking = true,
    pricing = pricing(price),
    default = i == 1,
  }
  chat_listed[i] = {
    id = id,
    tier = tier,
    context_window = context,
    max_output_tokens = out,
    supports_vision = vision,
    pricing = pricing(price),
  }
end

-- Mirrors the bundled `deepseek` plugin's back-fill: the gateway rejects a
-- thinking request with tool calls when an assistant message is missing
-- `reasoning_content`.
local function pad_reasoning_content(body, model, thinking)
  if not thinking or not body.tools or not model:match("^deepseek") then
    return
  end
  for _, message in ipairs(body.messages or {}) do
    if message.role == "assistant" and type(message.reasoning_content) ~= "string" then
      message.reasoning_content = ""
    end
  end
end

maki.provider.register({
  slug = "opencode-go-chat",
  display_name = "OpenCode Go (Chat)",
  codec = "openai",
  base_url = ZEN_BASE_URL,
  api_key_env = "OPENCODE_API_KEY",
  login_url = "https://opencode.ai/console",
  default_model = "deepseek-v4.1-flash",
  family = "generic",
  models = chat_rows,
  -- Without this pin maki lists the gateway's whole catalogue under this
  -- slug, including the responses-only models (grok, gpt-6-luna, muse-spark)
  -- and the Gemini-native model that the gateway rejects on
  -- /chat/completions, and would route non-DeepSeek models through the
  -- DeepSeek-oriented thinking dialect below. Pin the picker to the chat
  -- models this provider actually shapes.
  list_models = pin(chat_listed),
  -- `gpt-5-6` is used only as a wire shape (the reasoning_effort literal set and
  -- off = "none"), not as a GPT model claim; the gateway accepts the full set.
  openai = { thinking = { dialect = "gpt-5-6" } },
  auth = auth_bearer,
  -- Runs on the final body, after the thinking pass.
  build_body = function(_, body, model, opts)
    pad_reasoning_content(body, model, opts.thinking)
    return body
  end,
})

----------------------------------------------------------------------------
-- Responses: `opencode-go-responses` (codec "openai-responses")
----------------------------------------------------------------------------
--
-- OpenCode Go models that are served only over the OpenAI Responses API.
--
-- maki picks one wire format per models.dev provider, and models.dev marks
-- `opencode-go` as `@ai-sdk/openai-compatible`, so every model it knows about
-- is posted to /chat/completions. The gateway serves the models below on
-- /responses only and answers the rest of the catalogue there with:
--
--   API error (400): {"type":"error","error":{"type":
--   "ModelProtocolUnsupported","message":"Model does not support this
--   protocol."}}
--
-- A plugin cannot claim the `opencode-go` slug (models.dev owns it), so this
-- companion provider points the responses codec at the same gateway. Use
-- `opencode-go-responses/<model>` where you would have used
-- `opencode-go/<model>`. Everything else stays on the built-in provider.
--
-- Upstream issue: https://github.com/tontinton/maki/issues/1091
-- Endpoint table: https://opencode.ai/v2/docs/console/go/#endpoints

-- id, tier, family, context_window, max_output_tokens, vision,
-- pricing = { input, output, cache_write, cache_read } in USD per 1M tokens.
-- Values mirror models.dev; the gateway charges more above a context
-- threshold, which maki's flat per-model pricing cannot express, so the
-- quoted baseline (<= threshold) rate is used. Where the threshold is real
-- money (grok: 200k), context_window is declared at the threshold so maki's
-- compaction keeps every request inside the cheap tier.
local RESPONSES_MODELS = {
  -- 200k, not the model's 500k: the gateway only honours $2/$6 up to a 200k
  -- context. maki compacts at 80% of the window, so requests stay ~160k.
  { "grok-4.7", "strong", "generic", 200000, 131072, true, { 2.0, 6.0, 0.0, 0.5 } },
  { "grok-4.6", "strong", "generic", 500000, 131072, true, { 2.0, 6.0, 0.0, 0.5 } },
  { "gpt-6-luna", "weak", "gpt", 1050000, 128000, true, { 0.1, 0.5, 0.125, 0.01 } },
  { "gpt-5.6-luna", "weak", "gpt", 1050000, 128000, true, { 0.2, 1.2, 0.25, 0.02 } },
  { "muse-spark-1.3-contributor", "strong", "generic", 1048576, 131072, true, { 0.1, 0.2, 0.0, 0.002 } },
}

local responses_rows = {}
local responses_listed = {}
for i, m in ipairs(RESPONSES_MODELS) do
  local id, tier, family, context, out, vision, price = m[1], m[2], m[3], m[4], m[5], m[6], m[7]
  responses_rows[i] = {
    prefixes = { id },
    tier = tier,
    family = family,
    context_window = context,
    max_output_tokens = out,
    supports_vision = vision,
    pricing = pricing(price),
    default = i == 1,
  }
  responses_listed[i] = {
    id = id,
    tier = tier,
    context_window = context,
    max_output_tokens = out,
    supports_vision = vision,
    pricing = pricing(price),
  }
end

-- Reasoning effort on the Responses API.
--
-- The responses codec never runs the thinking pass (a TODO at codec.rs:511) and
-- refuses the `openai` wire (plugin.rs:384), so the effort has to be written to
-- the body here. This mirrors maki's own `apply_responses_reasoning`
-- (openai/responses.rs:46) and `Effort::snap` (maki-storage/src/sessions.rs:567),
-- using the built-in dialect for each model:
--   grok-4.6/4.7   -> "grok"     (low..xhigh; adaptive high; off omits — Grok
--                                cannot disable reasoning)
--   gpt-6-luna     -> "gpt-6"    (low..max; adaptive medium; off omits — `none`
--                                is rejected by GPT-6)
--   gpt-5.6-luna   -> "gpt-5-6"  (minimal..max; adaptive medium; off "none")
--   muse-spark-1.3 -> "standard" (minimal..max; adaptive medium; off omits)
local LEVELS = { "minimal", "low", "medium", "high", "xhigh", "max" }

local THINKING_DIALECTS = {
  { prefix = "grok-4.7", supported = { low = true, medium = true, high = true, xhigh = true }, adaptive = "high" },
  { prefix = "grok-4.6", supported = { low = true, medium = true, high = true, xhigh = true }, adaptive = "high" },
  { prefix = "gpt-6-luna", supported = { low = true, medium = true, high = true, xhigh = true, max = true }, adaptive = "medium" },
  { prefix = "gpt-5.6-luna", supported = { minimal = true, low = true, medium = true, high = true, xhigh = true, max = true }, adaptive = "medium", off = "none" },
  { prefix = "muse-spark-1.3-contributor", supported = { minimal = true, low = true, medium = true, high = true, xhigh = true, max = true }, adaptive = "medium" },
}

-- Longest matching prefix wins, as it does for a model table row.
local function dialect_for(model)
  local best = nil
  for _, d in ipairs(THINKING_DIALECTS) do
    if model:sub(1, #d.prefix) == d.prefix and (best == nil or #d.prefix > #best.prefix) then
      best = d
    end
  end
  return best
end

-- Effort::snap: exact match, else the closest lower supported level, else the
-- lowest supported level.
local function snap(level, supported)
  if supported[level] then
    return level
  end
  local idx = nil
  for i, l in ipairs(LEVELS) do
    if l == level then
      idx = i
      break
    end
  end
  if not idx then
    return nil
  end
  for i = idx - 1, 1, -1 do
    if supported[LEVELS[i]] then
      return LEVELS[i]
    end
  end
  for i = 1, #LEVELS do
    if supported[LEVELS[i]] then
      return LEVELS[i]
    end
  end
  return nil
end

local function resolve_effort(thinking, dialect)
  if thinking == "adaptive" then
    return dialect.adaptive
  end
  if dialect.supported[thinking] then
    return thinking
  end
  -- A token budget only reaches here for a model that declares one; these do
  -- not, so fall back to the dialect's adaptive value.
  if tonumber(thinking) then
    return dialect.adaptive
  end
  return snap(thinking, dialect.supported)
end

local function responses_build_body(_, body, model, opts)
  local dialect = dialect_for(model)
  if not dialect then
    return body
  end
  local thinking = opts and opts.thinking
  if thinking == nil then
    if dialect.off then
      body.reasoning = { effort = dialect.off }
    end
    return body
  end
  local effort = resolve_effort(thinking, dialect)
  if effort == nil then
    return body
  end
  local reasoning = { effort = effort }
  if effort ~= "none" then
    reasoning.summary = "auto"
  end
  body.reasoning = reasoning
  return body
end

maki.provider.register({
  slug = "opencode-go-responses",
  display_name = "OpenCode Go (Responses)",
  codec = "openai-responses",
  base_url = ZEN_BASE_URL,
  api_key_env = "OPENCODE_API_KEY",
  login_url = "https://opencode.ai/console",
  default_model = "grok-4.7",
  models = responses_rows,
  -- Without this pin maki lists the gateway's whole catalogue under this
  -- slug, and the chat-completions models would be posted to /responses and
  -- fail. The hook pins the picker to the responses-only models.
  list_models = pin(responses_listed),
  auth = auth_bearer,
  build_body = responses_build_body,
})

----------------------------------------------------------------------------
-- Gemini: `opencode-go-gemini` (codec "google")
----------------------------------------------------------------------------
--
-- OpenCode Go models that are served only over the native Gemini API.
--
-- maki picks one wire format per models.dev provider, and models.dev marks
-- `opencode-go` as `@ai-sdk/openai-compatible`, so every model it knows about
-- is posted to /chat/completions. The gateway serves the model below on the
-- Gemini route instead (`/v1/models/<id>`, the `@ai-sdk/google` SDK package)
-- and answers the rest of the catalogue there with:
--
--   API error (400): {"type":"error","error":{"type":
--   "ModelProtocolUnsupported","message":"Model does not support this
--   protocol."}}
--
-- A plugin cannot claim the `opencode-go` slug (models.dev owns it), so this
-- companion provider points the google codec at the same gateway. Use
-- `opencode-go-gemini/<model>` where you would have used
-- `opencode-go/<model>`. The chat-completions models stay on the built-in
-- provider (or `opencode-go-chat`), the responses-only models on
-- `opencode-go-responses`.
--
-- Upstream issue: https://github.com/tontinton/maki/issues/1091
-- Endpoint table: https://opencode.ai/v2/docs/console/go/#endpoints
-- Thinking levels: https://aihubmix.com/blog/gemini-4-argon-thinking-levels-and-long-decode-defaults-costs-and-when-to-use-each
--
-- Thinking levels: Argon has three — low, medium, high — and no off switch.
-- The API default is medium, but every published benchmark ran at high, so a
-- request that sets no level runs one step below the scores you have seen.
-- Google recommends medium for most work including complex code and agents,
-- high for the hardest reasoning/math/code, low for simpler cost-sensitive
-- work — and says to run your own evals at all three and keep the lowest
-- level that meets the bar. Because thinking cannot be off, the row below
-- sets `requires_thinking`: the picker drops "off", and an off request is
-- clamped to minimal effort instead of sending a misleading no-thinking
-- request.
--
-- Wire caveat: maki's google codec (0.6.3) only speaks the Gemini 2.5 knobs —
-- a token `thinkingBudget` for effort levels, `includeThoughts` for adaptive,
-- nothing for off — and the plugin API refuses both `build_body` and the
-- `openai` wire table on this codec, so `thinking_fields` would be dead
-- config here and there is no way to send Argon's native `thinkingLevel`.
-- The console's "Reasoning budget · N token budget" line is that 2.5-style
-- budget: 10/20/40/60/80/100% of 32,768 for minimal/low/medium/high/xhigh/max
-- against the 64k output cap, so minimal/low sit at the low end of the range
-- and high/xhigh/max at the high end. Adaptive sends `includeThoughts` with
-- no budget, leaving the level to the gateway default (medium). Keep one
-- level per session: implicit caching discounts repeated input 95% but needs
-- identical parameters, so switching levels can turn cached input back into
-- full-price input.
--
-- Output cap: `max_output_tokens` covers thinking and answer together, and
-- Google floors it at 32,768 — a hard prompt can otherwise spend the whole
-- budget thinking and come back empty ("incomplete"), still billed. 65,536
-- is the default and the ceiling for a single response; asking for more
-- without long decode returns 400, and maki sends no continuation hops, so
-- the 1M long-decode ceiling is out of reach here. Thinking bills as output
-- ($20/M on Go); at high, budget ~62k output tokens and ~45s to first token
-- per hard task, at ~100 tokens/s. Argon ignores temperature/top_p/top_k, so
-- there is nothing to tune there.

-- id, tier, context_window, max_output_tokens, vision,
-- pricing = { input, output, cache_write, cache_read } in USD per 1M tokens.
-- Values mirror the Go usage table ($4/$20, $0.20 cached read with no write
-- column; 1M shared input+output window; 64k single-response output cap —
-- the long-decode ceiling is higher, but maki sends no continuation hops, so
-- the default cap is what agentic turns see).
-- Every row requires thinking: Argon has no off switch (low/medium/high
-- only, default medium), so `requires_thinking` drops "off" from the picker
-- and clamps it to minimal effort. It implies `supports_thinking`.
local GEMINI_MODELS = {
  { "gemini-4-argon-contributor", "strong", 1048576, 65536, true, { 4.0, 20.0, 0.0, 0.2 } },
}

local gemini_rows = {}
local gemini_listed = {}
for i, m in ipairs(GEMINI_MODELS) do
  local id, tier, context, out, vision, price = m[1], m[2], m[3], m[4], m[5], m[6]
  gemini_rows[i] = {
    prefixes = { id },
    tier = tier,
    family = "gemini",
    context_window = context,
    max_output_tokens = out,
    supports_vision = vision,
    requires_thinking = true,
    pricing = pricing(price),
    default = i == 1,
  }
  gemini_listed[i] = {
    id = id,
    tier = tier,
    context_window = context,
    max_output_tokens = out,
    supports_vision = vision,
    -- ModelInfo cannot express `requires_thinking`; the declared row above
    -- carries it, and this keeps the runtime listing honest about support.
    supports_thinking = true,
    pricing = pricing(price),
  }
end

maki.provider.register({
  slug = "opencode-go-gemini",
  display_name = "OpenCode Go (Gemini)",
  codec = "google",
  base_url = GEMINI_BASE_URL,
  api_key_env = "OPENCODE_API_KEY",
  login_url = "https://opencode.ai/console",
  default_model = "gemini-4-argon-contributor",
  family = "gemini",
  models = gemini_rows,
  -- Without this pin maki lists the gateway's whole catalogue under this
  -- slug, and the chat-completions and responses models would be posted to
  -- the Gemini route and fail. The hook pins the picker to the Gemini-native
  -- model.
  list_models = pin(gemini_listed),
  auth = auth_google,
  -- NOTE: no `build_body` and no `openai` table — the google codec refuses
  -- both and registration would fail.
})

----------------------------------------------------------------------------
-- Anthropic: `opencode-go-anthropic` (codec "anthropic")
----------------------------------------------------------------------------
--
-- OpenCode Go models that are served only over the Anthropic Messages API.
--
-- The gateway serves the models below at
-- `https://opencode.ai/inference/go/anthropic/v1/messages` (the
-- `@ai-sdk/anthropic` SDK package) and answers the rest of the catalogue
-- there with `ModelProtocolUnsupported`, mirroring the responses/gemini
-- cases. maki's anthropic codec POSTs to `origin(base_url) ..
-- "/v1/messages"`, where `origin()` strips a trailing `/v1/messages`
-- (`mod.rs`), so the declared base carries no `/v1` suffix.
--
-- Thinking is native on this codec: `ThinkingConfig::apply_to_body`
-- (`types.rs`) writes the thinking block itself, so there is no `build_body`
-- and no `openai` table (both are refused on this codec — `build_body` is
-- "openai codecs only"). `claude-haiku-5-5` parses as family haiku ≥ (5,0),
-- so it takes the adaptive path (`{"type":"adaptive",
-- "display":"summarized"}` + `output_config.effort`, max `high`); non-Claude
-- ids take the legacy token-budget path (`{"type":"enabled",
-- "budget_tokens":n}`). Gateway acceptance of those budget blocks for
-- qwen/minimax was verified live 2026-10-18 (qwen3.8-flash answers at
-- `low` and `off`; haiku at `adaptive` and `off`), so all rows keep
-- `supports_thinking = true`.
--
-- Context caps follow the grok-4.7 precedent of declaring `context_window` at
-- the cheap-tier threshold so 80% compaction stays inside it: haiku is capped
-- at 100k (5× price jump above), qwen3.7-plus at 256k (3× above). The haiku
-- output ceiling is clamped to the declared window (maki rejects
-- max_output_tokens > context_window at registration); the census 128k
-- figure only applies inside the model's real 1M window.
--
-- Upstream issue: https://github.com/tontinton/maki/issues/1091
-- Endpoint table: https://opencode.ai/v2/docs/console/go/#endpoints

-- id, tier, family, context_window, max_output_tokens, vision,
-- pricing = { input, output, cache_write, cache_read } in USD per 1M.
-- Pricing is the Go-plan baseline (<= threshold) rate from the usage-limits
-- table; windows/output/vision/tiers mirror the opencode2api census snapshot.
local ANTHROPIC_MODELS = {
  { "claude-haiku-5-5", "medium", "claude", 100000, 100000, true, { 0.10, 0.50, 0.125, 0.01 } },
  { "minimax-m3", "medium", "generic", 1000000, 131072, true, { 0.30, 1.20, 0.0, 0.06 } },
  { "qwen3.8-max", "strong", "generic", 1000000, 131072, true, { 2.0, 6.0, 2.5, 0.25 } },
  { "qwen3.8-flash", "medium", "generic", 1000000, 131072, true, { 0.15, 0.47, 0.20, 0.016 } },
  { "qwen3.7-plus", "medium", "generic", 256000, 65536, true, { 0.40, 1.60, 0.50, 0.04 } },
}

local anthropic_rows = {}
local anthropic_listed = {}
for i, m in ipairs(ANTHROPIC_MODELS) do
  local id, tier, family, context, out, vision, price = m[1], m[2], m[3], m[4], m[5], m[6], m[7]
  anthropic_rows[i] = {
    prefixes = { id },
    tier = tier,
    family = family,
    context_window = context,
    max_output_tokens = out,
    supports_vision = vision,
    supports_thinking = true,
    pricing = pricing(price),
    default = i == 1,
  }
  anthropic_listed[i] = {
    id = id,
    tier = tier,
    context_window = context,
    max_output_tokens = out,
    supports_vision = vision,
    supports_thinking = true,
    pricing = pricing(price),
  }
end

maki.provider.register({
  slug = "opencode-go-anthropic",
  display_name = "OpenCode Go (Anthropic)",
  codec = "anthropic",
  base_url = ANTHROPIC_BASE_URL,
  api_key_env = "OPENCODE_API_KEY",
  login_url = "https://opencode.ai/console",
  default_model = "claude-haiku-5-5",
  models = anthropic_rows,
  -- Without this pin the codec would GET the gateway's whole catalogue under
  -- this slug, and the chat/responses/gemini models would be posted to
  -- /v1/messages and fail. The hook pins the picker to the
  -- Anthropic-route models.
  list_models = pin(anthropic_listed),
  auth = auth_anthropic,
  -- NOTE: no `build_body` and no `openai` table — both are refused on this
  -- codec. Thinking is applied natively by `ThinkingConfig::apply_to_body`.
})
