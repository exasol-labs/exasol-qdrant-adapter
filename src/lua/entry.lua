--- Thin entrypoint for the Qdrant Virtual Schema Lua adapter.
-- Defines the global adapter_call() function required by Exasol.
-- Contains no business logic — all requests are delegated to RequestDispatcher.

local QdrantAdapter    = require("adapter.QdrantAdapter")
local AdapterProperties = require("adapter.AdapterProperties")
local RequestDispatcher = require("exasol.vscl.RequestDispatcher")

function adapter_call(request_json)
    local adapter    = QdrantAdapter:new()
    local dispatcher = RequestDispatcher:new(adapter, AdapterProperties)
    return dispatcher:adapter_call(request_json)
end
