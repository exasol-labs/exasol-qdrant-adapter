--- QueryRewriter: embeds a query string via Ollama, searches Qdrant for
-- similar vectors, and returns a VALUES-based SELECT statement that
-- Exasol can materialise as a result set.

local http = require("util.http")

local QueryRewriter = {}
QueryRewriter.__index = QueryRewriter

local DEFAULT_LIMIT = 10

--- Creates a new QueryRewriter.
-- @param qdrant_url  string  Qdrant base URL (no trailing slash)
-- @param ollama_url  string  Ollama base URL (no trailing slash)
-- @param model       string  Ollama model name for embeddings
-- @param api_key     string  Qdrant API key, or "" if not required
function QueryRewriter:new(qdrant_url, ollama_url, model, api_key)
    return setmetatable({
        _qdrant_url = qdrant_url,
        _ollama_url = ollama_url,
        _model      = model,
        _api_key    = api_key or "",
    }, self)
end

--- Rewrites a push-down request to a SQL string.
-- @param request table  Parsed pushDown request (from virtual-schema-common-lua)
-- @return string        SQL suitable for the pushDown response
function QueryRewriter:rewrite(request)
    local collection = self:_extract_collection(request)
    local query_text = self:_extract_query_text(request)
    local limit      = self:_extract_limit(request)

    -- Graceful empty-query handling: if no WHERE "QUERY" = '...' clause was
    -- provided, return a single-row hint instead of crashing on Ollama.
    if query_text == nil or query_text == "" then
        return self:_build_empty_query_hint(collection)
    end

    local embedding = self:_embed(query_text)
    local results   = self:_search(collection, embedding, limit)

    return self:_build_sql(query_text, results)
end

-- ─────────────────────────────────────────────
-- Request parsing helpers

function QueryRewriter:_extract_collection(request)
    local tables = request.involvedTables or {}
    if not tables[1] then
        error("pushDown request contains no involved tables")
    end
    -- Qdrant collection names are lowercase; virtual table names are uppercase.
    return tables[1].name:lower()
end

function QueryRewriter:_extract_query_text(request)
    local push = request.pushdownRequest or {}
    if not push.filter then return "" end
    return self:_walk_filter(push.filter) or ""
end

--- Walks the filter AST looking for QUERY = '<literal>' (or '<literal>' = QUERY).
function QueryRewriter:_walk_filter(node)
    if not node then return nil end
    if node.type == "predicate_equal" then
        local left  = node.left  or {}
        local right = node.right or {}
        -- QUERY = 'text'
        if left.type == "column" and left.name and left.name:upper() == "QUERY"
           and right.type == "literal_string" then
            return right.value
        end
        -- 'text' = QUERY
        if right.type == "column" and right.name and right.name:upper() == "QUERY"
           and left.type == "literal_string" then
            return left.value
        end
    end
    return nil
end

function QueryRewriter:_extract_limit(request)
    local push = request.pushdownRequest or {}
    if push.limit and push.limit.numElements then
        return tonumber(push.limit.numElements) or DEFAULT_LIMIT
    end
    return DEFAULT_LIMIT
end

-- ─────────────────────────────────────────────
-- HTTP calls

--- Calls Ollama /api/embeddings and returns the embedding float array.
function QueryRewriter:_embed(query_text)
    local url = self._ollama_url .. "/api/embeddings"
    local response = http.post_json(url, {
        model  = self._model,
        prompt = query_text,
    })
    local embedding = response.embedding
    if not embedding or type(embedding) ~= "table" or #embedding == 0 then
        error("Ollama returned no embedding for model '" .. self._model .. "'")
    end
    return embedding
end

--- Serialises a float array from a cjson-decoded table into a JSON array string.
local function embedding_to_json(embedding)
    local n = #embedding
    if n == 0 then
        -- Diagnostic: check actual table contents
        local info = "len=" .. tostring(n) .. " type=" .. type(embedding)
        local cnt = 0
        for k, _ in pairs(embedding) do cnt = cnt + 1 end
        info = info .. " pairs_count=" .. cnt
        if cnt > 0 then
            for k, v in pairs(embedding) do
                info = info .. " sample_k=" .. tostring(k) .. "(" .. type(k) .. ")"
                break
            end
        end
        error("embedding array is empty: " .. info)
    end
    local parts = {}
    for i = 1, n do parts[i] = tostring(embedding[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
end

--- Calls Qdrant /collections/{name}/points/query and returns result rows.
function QueryRewriter:_search(collection, vector, limit)
    local url = string.format("%s/collections/%s/points/query",
                              self._qdrant_url, collection)
    local headers = {}
    if self._api_key ~= "" then
        headers["api-key"] = self._api_key
    end

    local body = string.format(
        '{"query":%s,"using":"text","limit":%d,"with_payload":true}',
        embedding_to_json(vector), limit
    )
    local response = http.post_raw(url, body, headers)

    local rows = {}
    for _, point in ipairs((response.result or {}).points or {}) do
        local payload = point.payload or {}
        rows[#rows + 1] = {
            id    = tostring(payload._original_id or point.id or ""),
            text  = tostring(payload.text or ""),
            score = tonumber(point.score) or 0.0,
        }
    end
    return rows
end

-- ─────────────────────────────────────────────
-- SQL builders

--- Returns a single-row hint when no query text was provided.
-- Sets SCORE=1 and QUERY to a descriptive string so the hint row
-- survives post-pushdown filtering (e.g. WHERE SCORE > 0.5 or LIKE).
function QueryRewriter:_build_empty_query_hint(collection)
    local hint = "Semantic search requires: WHERE \"QUERY\" = 'your search text'."
        .. " Only equality predicates on QUERY are supported (no LIKE, >, <, AND, OR)."
        .. " Example: SELECT \"ID\", \"TEXT\", \"SCORE\" FROM vector_schema."
        .. collection .. " WHERE \"QUERY\" = 'your search' LIMIT 10"
    hint = hint:gsub("'", "''")
    local query_hint = "Only equality predicates on QUERY are supported: WHERE \"QUERY\" = 'your text'"
    query_hint = query_hint:gsub("'", "''")
    return "SELECT * FROM VALUES"
        .. " (CAST('HINT' AS VARCHAR(2000000) UTF8),"
        .. " CAST('" .. hint .. "' AS VARCHAR(2000000) UTF8),"
        .. " CAST(1 AS DOUBLE),"
        .. " CAST('" .. query_hint .. "' AS VARCHAR(2000000) UTF8))"
        .. " AS t(ID, TEXT, SCORE, QUERY)"
end

local function sql_escape(s)
    return (s or ""):gsub("'", "''")
end

--- Builds the push-down SQL for non-empty results (VALUES clause).
-- For zero results, returns an empty-result query that preserves column types.
function QueryRewriter:_build_sql(query_text, results)
    if #results == 0 then
        return "SELECT"
            .. " CAST('' AS VARCHAR(36) UTF8) AS ID,"
            .. " CAST('' AS VARCHAR(2000000) UTF8) AS TEXT,"
            .. " CAST(0 AS DOUBLE) AS SCORE,"
            .. " CAST('' AS VARCHAR(2000000) UTF8) AS QUERY"
            .. " FROM DUAL WHERE FALSE"
    end

    local rows = {}
    local q = sql_escape(query_text)
    for _, r in ipairs(results) do
        rows[#rows + 1] = string.format(
            "(CAST('%s' AS VARCHAR(2000000) UTF8),"
            .. "CAST('%s' AS VARCHAR(2000000) UTF8),"
            .. "CAST(%s AS DOUBLE),"
            .. "CAST('%s' AS VARCHAR(2000000) UTF8))",
            sql_escape(r.id),
            sql_escape(r.text),
            tostring(r.score),
            q
        )
    end

    return "SELECT * FROM VALUES " .. table.concat(rows, ",") .. " AS t(ID, TEXT, SCORE, QUERY)"
end

return QueryRewriter
