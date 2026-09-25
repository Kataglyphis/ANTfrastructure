-- geniex-shape: per-route GenieX request shaping for the llm-stack gateway.
-- Rules, and the lane policy geniex_hook applies: linux/llm-stack/README.md § Gateway.
local core = require("apisix.core")
local plugin = require("apisix.plugin")
local resty_sha256 = require("resty.sha256")
local to_hex = require("resty.string").to_hex
local ngx = ngx
local type = type
local ipairs = ipairs
local tonumber = tonumber
local math_ceil = math.ceil

local NAME = "geniex-shape"

local lane_policy = {
    type = "object",
    properties = {
        timeout_ms = {type = "integer", minimum = 1},
        t0_rewrite = {type = "boolean"},
        overflow_relabel = {type = "boolean"},
    },
    required = {"timeout_ms", "t0_rewrite", "overflow_relabel"},
    additionalProperties = false,
}

local schema = {
    type = "object",
    properties = {
        primary = {type = "string", minLength = 1},
        tag = {type = "string", enum = {"no", "presend"}},
        estimate = {type = "boolean"},
        drop_fields = {type = "array", items = {type = "string", minLength = 1}},
        tools_prompt = {
            type = "object",
            properties = {
                name = {type = "string", minLength = 1},
                sha256 = {type = "string", pattern = "^[0-9a-f]{64}$"},
                b64 = {type = "string", minLength = 4},
            },
            required = {"name", "sha256", "b64"},
            additionalProperties = false,
        },
        lanes = {type = "object", minProperties = 1, additionalProperties = lane_policy},
    },
    required = {"primary", "tag", "estimate", "drop_fields", "lanes"},
    additionalProperties = false,
}

local metadata_schema = {
    type = "object",
    properties = {
        bytes_per_token = {type = "number", minimum = 0.5},
        default_reserve = {type = "integer", minimum = 0},
        prompt_bytes = {type = "object"},
    },
    required = {"bytes_per_token", "default_reserve", "prompt_bytes"},
}

local _M = {
    version = 0.1,
    priority = 1045,
    name = NAME,
    schema = schema,
    metadata_schema = metadata_schema,
}


function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end
    return core.schema.check(schema, conf)
end


local function has_tools(body)
    return type(body.tools) == "table" and #body.tools > 0
end


-- R3a: read by the router (before any plugin runs), so it counts the prompt R2 adds.
local function estimate_tokens(ctx)
    local body = core.request.get_json_request_body_table()
    local md = plugin.plugin_metadata(NAME)
    if type(body) ~= "table" or not md then
        return 0
    end
    local m = md.value
    local bytes = #(core.request.get_body(nil, ctx) or "")
    if has_tools(body) then
        bytes = bytes + (tonumber(m.prompt_bytes[body.model]) or 0)
    end
    local reserve = tonumber(body.max_tokens) or tonumber(body.max_completion_tokens)
                    or m.default_reserve
    return math_ceil(bytes / m.bytes_per_token) + reserve
end
core.ctx.register_var("gw_est_tokens", estimate_tokens)

for _, field in ipairs({"lane", "rerouted", "prompt", "est"}) do
    local key = "gw_" .. field
    core.ctx.register_var(key, function(ctx) return ctx[key] end, {no_cacheable = true})
end
core.ctx.register_var("gw_stream_aborted", function(ctx)
    return ctx.gw_lane and (ctx.ai_stream_aborted or "-")
end, {no_cacheable = true})


local prompt_cache = {}

local function verified_prompt(tp)
    local key = tp.sha256 .. tp.b64
    local hit = prompt_cache[key]
    if hit == nil then
        local raw = ngx.decode_base64(tp.b64)
        hit = false
        if raw then
            local h = resty_sha256:new()
            h:update(raw)
            hit = to_hex(h:final()) == tp.sha256 and raw
        end
        prompt_cache[key] = hit
    end
    return hit or nil
end


-- R2: the pinned prompt goes first; a request that already starts with it is left alone.
local function add_tools_prompt(tp, body, ctx)
    local prompt = verified_prompt(tp)
    if not prompt then
        core.log.error(NAME, ": tools prompt ", tp.name, " does not match its pinned sha256")
        return nil, {error = {message = "the gateway's tools prompt failed its sha256 check",
                              type = "server_error", code = "gateway_prompt_mismatch"}}
    end
    ctx.gw_prompt = tp.name
    local first = body.messages[1]
    if type(first) == "table" and first.role == "system" and first.content == prompt then
        return false
    end
    core.table.insert(body.messages, 1, {role = "system", content = prompt})
    return true
end


function _M.rewrite(conf, ctx)
    ctx.gw_lanes = conf.lanes
    ctx.gw_primary = conf.primary
    ctx.gw_tag = conf.tag
    if conf.estimate then
        ctx.gw_est = ctx.var.gw_est_tokens
    end
    local body = core.request.get_json_request_body_table()
    if type(body) ~= "table" then
        return  -- ai-proxy-multi answers a bad body itself
    end
    local changed = false
    for _, field in ipairs(conf.drop_fields) do
        if body[field] ~= nil then
            body[field] = nil
            changed = true
        end
    end
    if conf.tools_prompt and has_tools(body) and type(body.messages) == "table" then
        local added, err = add_tools_prompt(conf.tools_prompt, body, ctx)
        if err then
            return 500, err
        end
        changed = changed or added
    end
    if changed then
        ngx.req.set_body_data(core.json.encode(body))
        ctx.ai_request_body_changed = true
    end
end


-- R9: runs before the body leaves, so the tags reach the client and the log line.
function _M.header_filter(conf, ctx)
    local lane = ctx.picked_ai_instance_name
    local rerouted = conf.tag
    if ctx.gw_overflow then
        rerouted = "overflow"
    elseif lane and lane ~= conf.primary then
        rerouted = "fallback"
    end
    ctx.gw_lane = lane or "-"
    ctx.gw_rerouted = rerouted
    ctx.gw_prompt = ctx.gw_prompt or "-"
    core.response.set_header("X-Gw-Lane", ctx.gw_lane)
    core.response.set_header("X-Gw-Rerouted", rerouted)
end


return _M
