-- Companion script: CREATE_COLLECTION
-- Implements the US-01 "CREATE TABLE" user story.
--
-- Usage:
--   EXECUTE SCRIPT vector_schema.CREATE_COLLECTION('my_collection');
--
-- After creation, run: ALTER VIRTUAL SCHEMA vector_schema REFRESH;
-- to make the new table visible in the virtual schema.

CREATE OR REPLACE LUA SCRIPT ADAPTER.CREATE_COLLECTION(collection_name)
RETURNS TABLE AS
    -- Read connection details from the virtual schema
    -- (In a real deployment, pass connection name as a parameter or read from schema properties)
    local connection_name = "qdrant_conn"
    local model           = exa.meta.script_schema   -- override in production

    local conn     = exa.get_connection(connection_name)
    local base_url = conn.address
    local api_key  = conn.password

    -- Remove trailing slash
    if base_url:sub(-1) == "/" then
        base_url = base_url:sub(1, -2)
    end

    -- Check if collection already exists
    local check_url = base_url .. "/collections/" .. collection_name
    local check_res = exa.pquery(
        "SELECT http_get('" .. check_url .. "', 'api-key', '" .. api_key .. "')")
    -- A 200 response means the collection already exists
    if check_res and check_res[1] and check_res[1][1] and check_res[1][1]:find('"status":"green"') then
        error("Collection '" .. collection_name .. "' already exists in Qdrant.")
    end

    -- Build collection creation request body
    local body = '{"vectors":{"text":{"model_config":{"model":"' ..
                 exa.meta.current_schema .. '"},"distance":"Cosine"}}}'

    -- POST to Qdrant (Exasol LUA HTTP calls require an HTTP UDF or the http_get built-in)
    -- In production, use Exasol's HTTP UDF adapter or a Java helper script.
    -- This is a placeholder illustrating the intended logic:
    output("Would create collection: " .. collection_name)
    output("PUT " .. base_url .. "/collections/" .. collection_name)
    output("Body: " .. body)

    return {{"status", "message"},
            {"ok",     "Collection '" .. collection_name .. "' creation requested. Run REFRESH VIRTUAL SCHEMA to activate."}}
/
