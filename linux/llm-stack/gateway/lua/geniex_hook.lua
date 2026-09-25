-- geniex_hook: four patches of APISIX 3.18.0 internals for the GenieX lanes.
-- What each does, and the e2e test that re-proves it: linux/llm-stack/README.md § Gateway.
local apisix = require("apisix")
local ngx = ngx
local type = type
local error = error
local ipairs = ipairs

local PROVEN_ON = "3.18.0"
local MAX_TIMEOUT_MS = 1800000

local _M = {version = 0.1}


local function need(value, what)
    if not value then
        error("geniex_hook: " .. what .. " moved; re-prove the hook before this APISIX ships", 2)
    end
    return value
end


-- 1: ai-proxy(-multi) caps `timeout` at 600000 ms; the GGUF lanes need 1800000.
local function raise_timeout_cap()
    local schema = require("apisix.plugins.ai-proxy.schema")
    for _, name in ipairs({"ai_proxy_schema", "ai_proxy_multi_schema"}) do
        local t = need(schema[name] and schema[name].properties
                       and schema[name].properties.timeout, name .. ".properties.timeout")
        need(type(t.maximum) == "number", name .. ".properties.timeout.maximum")
        if t.maximum < MAX_TIMEOUT_MS then
            t.maximum = MAX_TIMEOUT_MS
        end
    end
end


-- Hand the base plugin back the 400 body this hook had to read.
local function reserve_body(res, text, err)
    local served = false
    res.read_body = function() return text, err end
    res.body_reader = function()
        if served then
            return nil
        end
        served = true
        return text, err
    end
end


-- 2-3: per-lane timeout and T=0 rewrite, and the overflow 400 relabelled 503 so
-- fallback_strategy http_5xx moves it to the next lane once.
local function wrap_transport()
    local transport = require("apisix.plugins.ai-transport.http")
    local request = need(type(transport.request) == "function" and transport.request,
                         "ai-transport.http.request")
    transport.request = function(params, timeout)
        local ctx = ngx.ctx.api_ctx
        local lanes = ctx and ctx.gw_lanes
        local lane = lanes and lanes[ctx.picked_ai_instance_name]
        if not lane then
            return request(params, timeout)
        end
        local body = params.body
        if lane.t0_rewrite and type(body) == "table" and body.temperature == 0 then
            body.temperature = 0.01
            body.top_k = 1
        end
        local res, err, meta = request(params, lane.timeout_ms)
        if res and res.status == 400 and lane.overflow_relabel then
            local text, rerr = res:read_body()
            if text and text:find("context_length_exceeded", 1, true) then
                res.status = 503
                ctx.gw_overflow = true
            end
            reserve_body(res, text, rerr)
        end
        return res, err, meta
    end
end


-- 4: once response headers are out, a lane failure ends the stream; it never
-- sends the whole request to a second lane that would generate for nobody.
local function no_fallback_after_headers()
    local base = require("apisix.plugins.ai-proxy.base")
    local before_proxy = need(type(base.before_proxy) == "function" and base.before_proxy,
                              "ai-proxy.base.before_proxy")
    base.before_proxy = function(conf, ctx, on_error)
        if not on_error then
            return before_proxy(conf, ctx, on_error)
        end
        return before_proxy(conf, ctx, function(c, cf, code, body)
            if ngx.headers_sent then
                ngx.log(ngx.WARN, "geniex_hook: lane failed with ", code,
                        " after the response started; not falling back")
                return code
            end
            return on_error(c, cf, code, body)
        end)
    end
end


local http_init_worker = need(apisix.http_init_worker, "apisix.http_init_worker")

apisix.http_init_worker = function(...)
    local version = require("apisix.core").version.VERSION
    if version ~= PROVEN_ON then
        ngx.log(ngx.WARN, "geniex_hook: proven on APISIX ", PROVEN_ON, ", running on ",
                version, "; run the gateway e2e test before trusting it")
    end
    raise_timeout_cap()
    wrap_transport()
    no_fallback_after_headers()
    return http_init_worker(...)
end


return _M
