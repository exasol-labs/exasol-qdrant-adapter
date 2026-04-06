--- Thin entrypoint for the Qdrant Virtual Schema Lua adapter.
-- Defines the global adapter_call() function required by Exasol.
-- Contains no business logic — all requests are delegated to RequestDispatcher.

-- Adapter version: update this on each release for deployment tracking.
-- Queryable via: SELECT SCRIPT_TEXT FROM SYS.EXA_ALL_SCRIPTS
--                WHERE SCRIPT_NAME = 'QDRANT_ADAPTER' AND SCRIPT_SCHEMA = 'ADAPTER';
local ADAPTER_VERSION = "2.1.0"

local QdrantAdapter    = require("adapter.QdrantAdapter")
local AdapterProperties = require("adapter.AdapterProperties")
local RequestDispatcher = require("exasol.vscl.RequestDispatcher")

function adapter_call(request_json)
    local adapter    = QdrantAdapter:new()
    local dispatcher = RequestDispatcher:new(adapter, AdapterProperties)
    return dispatcher:adapter_call(request_json)
end
