--- HTTP utility module for the Qdrant Virtual Schema Lua adapter.
-- Provides JSON GET and POST helpers built on LuaSocket (bundled in Exasol).
-- All functions return a decoded Lua table on success and raise an error on failure.

local socket_http = require("socket.http")
local ltn12       = require("ltn12")
local cjson       = require("cjson")

local M = {}

--- Executes an HTTP request and returns (status_code, body_string).
-- @param opts table passed directly to socket.http.request
local function do_request(opts)
    local chunks = {}
    opts.sink = ltn12.sink.table(chunks)
    local _, code, _ = socket_http.request(opts)
    local body = table.concat(chunks)
    if type(code) ~= "number" then
        error("HTTP request to " .. (opts.url or "?") .. " failed: " .. tostring(code))
    end
    return code, body
end

--- Makes an HTTP GET request and returns the decoded JSON response body.
-- @param url     string  Full URL to GET
-- @param headers table   Optional extra headers (e.g. {"api-key": "..."})
-- @return table  Decoded JSON response
function M.get_json(url, headers)
    local code, body = do_request({
        url     = url,
        method  = "GET",
        headers = headers or {},
    })
    if code >= 400 then
        error(string.format("HTTP GET %s returned %d: %s", url, code, body))
    end
    return cjson.decode(body)
end

--- Makes an HTTP POST request with a JSON-encoded payload.
-- @param url     string  Full URL to POST to
-- @param payload table   Lua table to encode as JSON body
-- @param headers table   Optional extra headers merged with Content-Type/Content-Length
-- @return table  Decoded JSON response
function M.post_json(url, payload, headers)
    local body    = cjson.encode(payload)
    local req_headers = headers or {}
    req_headers["Content-Type"]   = "application/json"
    req_headers["Content-Length"] = tostring(#body)

    local code, resp_body = do_request({
        url     = url,
        method  = "POST",
        headers = req_headers,
        source  = ltn12.source.string(body),
    })
    if code >= 400 then
        error(string.format("HTTP POST %s returned %d: %s", url, code, resp_body))
    end
    return cjson.decode(resp_body)
end

--- Makes an HTTP POST request with a pre-encoded string body.
-- Use this when the body must be built manually (e.g. to avoid cjson
-- encoding a decoded sub-table as {} instead of [...]).
-- @param url     string  Full URL to POST to
-- @param body    string  Already-encoded request body
-- @param headers table   Optional extra headers merged with Content-Type/Content-Length
-- @return table  Decoded JSON response
function M.post_raw(url, body, headers)
    local req_headers = headers or {}
    req_headers["Content-Type"]   = "application/json"
    req_headers["Content-Length"] = tostring(#body)

    local code, resp_body = do_request({
        url     = url,
        method  = "POST",
        headers = req_headers,
        source  = ltn12.source.string(body),
    })
    if code >= 400 then
        error(string.format("HTTP POST %s returned %d: %s", url, code, resp_body))
    end
    return cjson.decode(resp_body)
end

return M
