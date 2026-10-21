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

-- Live catalogue for the `list_models` hooks: id-only, unauthenticated.
-- Absolute URL on purpose — the anthropic origin 404s a relative `/v1/models`
-- (its path root is `/anthropic`, not `/v1`), so building from ctx.base_url
-- would break that slug's listing.
local CATALOG_URL = "https://opencode.ai/inference/go/v1/models"

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

-- Family routing: which gateway ids each slug lists.
--
-- An id belongs to a slug when it starts with one of the slug's literal
-- prefixes, plus/minus one exact-id exception: `minimax-m3.1-flash-free` is
-- chat-route while the rest of `minimax-` is Anthropic-route. Anything else
-- (kimi-, mimo-, longcat-, hy, step-, beam-, omen-alpha, …) is hidden from
-- all four slugs and stays on the built-in `opencode-go` provider.
local CHAT_EXCEPTION = "minimax-m3.1-flash-free"

local SLUG_RULES = {
  ["opencode-go-chat"] = {
    prefixes = { "deepseek-", "glm-" },
    include = { [CHAT_EXCEPTION] = true },
    thinking = true,
  },
  ["opencode-go-responses"] = {
    prefixes = { "grok-", "gpt-", "muse-spark-" },
  },
  ["opencode-go-gemini"] = {
    prefixes = { "gemini-" },
    thinking = true,
  },
  ["opencode-go-anthropic"] = {
    prefixes = { "claude-", "qwen", "minimax-" },
    exclude = { [CHAT_EXCEPTION] = true },
    thinking = true,
  },
}

-- Fallback description for a gateway id no curated row names yet (a future
-- `grok-4.8`): the family's default tier and flagship-typical windows and
-- vision. Deliberately no pricing — an unpriced model renders cost-unknown,
-- never $0 — and no cheap-tier cap, which is curated per id once its
-- threshold is known (cf. grok-4.7 below). Fields: tier, context_window,
-- max_output_tokens, supports_vision.
local FAMILY_GUESS = {
  ["deepseek-"] = { "medium", 1000000, 384000, false },
  ["glm-"] = { "medium", 1000000, 131072, false },
  ["grok-"] = { "strong", 500000, 131072, true },
  ["gpt-"] = { "weak", 1050000, 128000, true },
  ["muse-spark-"] = { "strong", 1048576, 131072, true },
  ["gemini-"] = { "strong", 1048576, 65536, true },
  ["claude-"] = { "medium", 1000000, 128000, true },
  ["qwen"] = { "medium", 1000000, 131072, true },
  ["minimax-"] = { "medium", 1000000, 131072, true },
}

-- One curated table per slug drives both the static `models` rows and the
-- offline `list_models` fallback, so the two can never disagree. Spec fields:
-- id, tier, family, context_window, max_output_tokens, supports_vision,
-- pricing { input, output, cache_write, cache_read } per 1M tokens or nil.
-- Static rows stay exact-id: maki unions every static prefix into the picker,
-- so a family prefix there would list a bogus `slug/grok-` spec. `thinking`
-- marks rows that keep `supports_thinking`; responses omits it as before.
local function build_models(specs, opts)
  local rows, listed, by_id = {}, {}, {}
  for i, s in ipairs(specs) do
    local id, tier, family, context, out, vision, price = s[1], s[2], s[3], s[4], s[5], s[6], s[7]
    local row = {
      prefixes = { id },
      tier = tier,
      family = family,
      context_window = context,
      max_output_tokens = out,
      supports_vision = vision,
    }
    if opts.requires_thinking then
      row.requires_thinking = true
    elseif opts.thinking then
      row.supports_thinking = true
    end
    if price then
      row.pricing = pricing(price)
    end
    if id == opts.default_id then
      row.default = true
    end
    rows[i] = row
    local info = {
      id = id,
      tier = tier,
      context_window = context,
      max_output_tokens = out,
      supports_vision = vision,
    }
    if opts.thinking then
      info.supports_thinking = true
    end
    if price then
      info.pricing = pricing(price)
    end
    listed[i] = info
    by_id[id] = info
  end
  return rows, listed, by_id
end

local function rule_matches(rule, id)
  if rule.exclude and rule.exclude[id] then
    return false
  end
  if rule.include and rule.include[id] then
    return true
  end
  for _, p in ipairs(rule.prefixes) do
    if id:sub(1, #p) == p then
      return true
    end
  end
  return false
end

-- Longest matching prefix wins, as it does for a model table row.
local function guess_for(prefixes, id)
  local best = nil
  for _, p in ipairs(prefixes) do
    if id:sub(1, #p) == p and (best == nil or #p > #best) then
      best = p
    end
  end
  return best and FAMILY_GUESS[best] or nil
end

-- Lists the slug's slice of the live gateway catalogue. Known ids re-emit
-- their curated row; unknown same-family ids get the family guess (no
-- pricing: cost-unknown until curated). On any fetch or shape failure the
-- hook warns and returns the slug's curated ids, so the picker works offline.
local function make_list_models(slug, by_id, fallback)
  local rule = SLUG_RULES[slug]
  return function(ctx)
    local body, err = ctx.get_json(CATALOG_URL)
    local data = type(body) == "table" and body.data or nil
    if type(data) ~= "table" then
      maki.log.warn(slug .. ": gateway catalogue unreachable (" .. tostring(err) .. "); listing " .. #fallback .. " curated models")
      return fallback
    end
    local out, seen = {}, {}
    for _, m in ipairs(data) do
      local id = type(m) == "table" and m.id or nil
      if type(id) == "string" and not seen[id] and rule_matches(rule, id) then
        seen[id] = true
        local known = by_id[id]
        if known then
          out[#out + 1] = known
        else
          local info = { id = id, tier = "medium" }
          local g = guess_for(rule.prefixes, id)
          if g then
            info.tier = g[1]
            info.context_window = g[2]
            info.max_output_tokens = g[3]
            info.supports_vision = g[4]
          end
          if rule.thinking then
            info.supports_thinking = true
          end
          out[#out + 1] = info
        end
      end
    end
    return out
  end
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

-- id, tier, family, context_window, max_output_tokens, vision,
-- pricing = { input, output, cache_write, cache_read } in USD per 1M tokens.
-- Values mirror models.dev. `minimax-m3.1-flash-free` is the family exception
-- (chat-route, priced $0 — it really is free); `glm-5.1` has no models.dev
-- entry yet, so it carries sibling-typical windows and no price.
local CHAT_MODELS = {
  { "deepseek-v4.1-flash", "medium", "generic", 1000000, 384000, true, { 0.15, 0.6, 0.0, 0.003 } },
  { "deepseek-v4-pro", "strong", "generic", 1000000, 384000, false, { 0.66, 1.98, 0.0, 0.022 } },
  { "glm-5.3-flash", "medium", "generic", 1000000, 131072, true, { 0.15, 0.5, 0.0, 0.03 } },
  { "glm-5.1", "medium", "generic", 1000000, 131072, false, nil },
  { "glm-5.2", "strong", "generic", 1000000, 131072, false, { 1.4, 4.4, 0.0, 0.26 } },
  { "glm-5.3", "strong", "generic", 1000000, 131072, false, { 1.4, 4.4, 0.0, 0.26 } },
  { "minimax-m3.1-flash-free", "medium", "generic", 1000000, 512000, true, { 0.0, 0.0, 0.0, 0.0 } },
}

-- Keeps the picker offering the full ladder even though the wire below is
-- what decides which levels are actually meaningful.
local chat_rows, chat_listed, chat_by_id = build_models(CHAT_MODELS, {
  thinking = true,
  default_id = "deepseek-v4.1-flash",
})

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
  -- Without this filter maki lists the gateway's whole catalogue under this
  -- slug, including the responses-only models (grok, gpt-*, muse-spark) and
  -- the Gemini-native model that the gateway rejects on /chat/completions.
  -- The hook lists only the deepseek-/glm- families plus the minimax
  -- exception, so a future `glm-5.4` appears without a code change while an
  -- id from another family can never be posted to the wrong route.
  list_models = make_list_models("opencode-go-chat", chat_by_id, chat_listed),
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
-- money, context_window is declared at the threshold so maki's compaction
-- keeps every request inside the cheap tier. `grok-4.6` has no models.dev
-- entry; its row keeps the last published grok baseline.
local RESPONSES_MODELS = {
  -- 200k, not the model's 500k: the gateway only honours $2/$6 up to a 200k
  -- context. maki compacts at 80% of the window, so requests stay ~160k.
  -- The cap lives on grok-4.7's own row, not the family guess: a future grok
  -- id gets the full window until its threshold is known.
  { "grok-4.7", "strong", "generic", 200000, 131072, true, { 2.0, 6.0, 0.0, 0.5 } },
  { "grok-4.6", "strong", "generic", 500000, 131072, true, { 2.0, 6.0, 0.0, 0.5 } },
  { "gpt-6-luna", "weak", "gpt", 1050000, 128000, true, { 0.1, 0.5, 0.125, 0.01 } },
  { "gpt-5.6-luna", "weak", "gpt", 1050000, 128000, true, { 0.2, 1.2, 0.25, 0.02 } },
  { "muse-spark-1.3-contributor", "strong", "generic", 1048576, 131072, true, { 0.1, 0.2, 0.0, 0.002 } },
  { "muse-spark-1.2-contributor", "strong", "generic", 1048576, 131072, true, { 0.1, 0.2, 0.0, 0.002 } },
}

local responses_rows, responses_listed, responses_by_id = build_models(RESPONSES_MODELS, {
  default_id = "grok-4.7",
})

-- Reasoning effort on the Responses API.
--
-- The responses codec never runs the thinking pass (a TODO at codec.rs:511) and
-- refuses the `openai` wire (plugin.rs:384), so the effort has to be written to
-- the body here. This mirrors maki's own `apply_responses_reasoning`
-- (openai/responses.rs:46) and `Effort::snap` (maki-storage/src/sessions.rs:567),
-- using the built-in dialect for each family (longest prefix wins, so
-- `gpt-5.6-` beats the `gpt-` fallback):
--   grok-        -> "grok"     (low..xhigh; adaptive high; off omits — Grok
--                               cannot disable reasoning)
--   gpt-6-       -> "gpt-6"    (low..max; adaptive medium; off omits — `none`
--                               is rejected by GPT-6)
--   gpt-5.6-     -> "gpt-5-6"  (minimal..max; adaptive medium; off "none")
--   gpt-         -> "gpt-6"    (fallback for an unknown GPT: omitting `off`
--                               is safer than sending `none` to it)
--   muse-spark-  -> "standard" (minimal..max; adaptive medium; off omits)
local LEVELS = { "minimal", "low", "medium", "high", "xhigh", "max" }

local THINKING_DIALECTS = {
  { prefix = "grok-", supported = { low = true, medium = true, high = true, xhigh = true }, adaptive = "high" },
  { prefix = "gpt-6-", supported = { low = true, medium = true, high = true, xhigh = true, max = true }, adaptive = "medium" },
  { prefix = "gpt-5.6-", supported = { minimal = true, low = true, medium = true, high = true, xhigh = true, max = true }, adaptive = "medium", off = "none" },
  { prefix = "gpt-", supported = { low = true, medium = true, high = true, xhigh = true, max = true }, adaptive = "medium" },
  { prefix = "muse-spark-", supported = { minimal = true, low = true, medium = true, high = true, xhigh = true, max = true }, adaptive = "medium" },
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
  -- Applies only to models without a row — every curated id above names its
  -- own family, so this is just the guess for a future uncurated one, where
  -- generic covers the grok/muse-spark majority.
  family = "generic",
  models = responses_rows,
  -- Without this filter maki lists the gateway's whole catalogue under this
  -- slug, and the chat-completions models would be posted to /responses and
  -- fail. The hook lists only the grok-/gpt-/muse-spark- families.
  list_models = make_list_models("opencode-go-responses", responses_by_id, responses_listed),
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

-- id, tier, family, context_window, max_output_tokens, vision,
-- pricing = { input, output, cache_write, cache_read } in USD per 1M tokens.
-- Values mirror the Go usage table ($4/$20, $0.20 cached read with no write
-- column; 1M shared input+output window; 64k single-response output cap —
-- the long-decode ceiling is higher, but maki sends no continuation hops, so
-- the default cap is what agentic turns see).
-- Every row requires thinking: Argon has no off switch (low/medium/high
-- only, default medium), so `requires_thinking` drops "off" from the picker
-- and clamps it to minimal effort. It implies `supports_thinking`. (A future
-- uncurated gemini- id gets plain `supports_thinking` from discovery until
-- it gets its own row — the listing cannot express `requires_thinking`.)
local GEMINI_MODELS = {
  { "gemini-4-argon-contributor", "strong", "gemini", 1048576, 65536, true, { 4.0, 20.0, 0.0, 0.2 } },
}

local gemini_rows, gemini_listed, gemini_by_id = build_models(GEMINI_MODELS, {
  thinking = true,
  requires_thinking = true,
  default_id = "gemini-4-argon-contributor",
})

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
  -- Without this filter maki lists the gateway's whole catalogue under this
  -- slug, and the chat-completions and responses models would be posted to
  -- the Gemini route and fail. The hook lists only the gemini- family.
  list_models = make_list_models("opencode-go-gemini", gemini_by_id, gemini_listed),
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
-- `minimax-m2.5`, `qwen3.6-plus`, and `qwen3.7-max` have no models.dev entry
-- yet: sibling-typical windows and vision, no price. qwen3.6-plus keeps the
-- full 1M window — a sibling's cheap-tier cap is never inherited
-- speculatively (cf. grok-4.6) — and the `-max` suffix promotes qwen3.7-max
-- to strong, matching qwen3.8-max.
local ANTHROPIC_MODELS = {
  { "claude-haiku-5-5", "medium", "claude", 100000, 100000, true, { 0.10, 0.50, 0.125, 0.01 } },
  { "minimax-m3", "medium", "generic", 1000000, 131072, true, { 0.30, 1.20, 0.0, 0.06 } },
  { "minimax-m2.5", "medium", "generic", 204800, 131072, false, nil },
  { "minimax-m2.7", "medium", "generic", 204800, 131072, false, { 0.3, 1.2, 0.375, 0.06 } },
  { "qwen3.8-max", "strong", "generic", 1000000, 131072, true, { 2.0, 6.0, 2.5, 0.25 } },
  { "qwen3.8-flash", "medium", "generic", 1000000, 131072, true, { 0.15, 0.47, 0.20, 0.016 } },
  { "qwen3.7-plus", "medium", "generic", 256000, 65536, true, { 0.40, 1.60, 0.50, 0.04 } },
  { "qwen3.6-plus", "medium", "generic", 1000000, 65536, true, nil },
  { "qwen3.7-max", "strong", "generic", 1000000, 131072, true, nil },
}

local anthropic_rows, anthropic_listed, anthropic_by_id = build_models(ANTHROPIC_MODELS, {
  thinking = true,
  default_id = "claude-haiku-5-5",
})

maki.provider.register({
  slug = "opencode-go-anthropic",
  display_name = "OpenCode Go (Anthropic)",
  codec = "anthropic",
  base_url = ANTHROPIC_BASE_URL,
  api_key_env = "OPENCODE_API_KEY",
  login_url = "https://opencode.ai/console",
  default_model = "claude-haiku-5-5",
  -- Applies only to models without a row — every curated id above names its
  -- own family, so this is just the guess for a future uncurated one, where
  -- generic covers the qwen/minimax majority.
  family = "generic",
  models = anthropic_rows,
  -- Without this filter the codec would GET the gateway's whole catalogue
  -- under this slug, and the chat/responses/gemini models would be posted
  -- to /v1/messages and fail. The hook lists only the claude-/qwen/minimax-
  -- families minus the chat-route minimax exception.
  list_models = make_list_models("opencode-go-anthropic", anthropic_by_id, anthropic_listed),
  auth = auth_anthropic,
  -- NOTE: no `build_body` and no `openai` table — both are refused on this
  -- codec. Thinking is applied natively by `ThinkingConfig::apply_to_body`.
})
