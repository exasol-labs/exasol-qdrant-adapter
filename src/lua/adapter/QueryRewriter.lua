--- QueryRewriter: builds the pushdown SQL response.
--
-- Returns SQL that calls ADAPTER.SEARCH_QDRANT_LOCAL (a SET UDF). All embed +
-- Qdrant search work happens inside that UDF when Exasol executes the
-- returned SQL — the Lua adapter never runs SQL or HTTP itself during
-- pushdown (Exasol forbids exa.pquery_no_preprocessing in pushdown context,
-- and the canonical workaround is a row-emitting UDF).

local QueryRewriter = {}
QueryRewriter.__index = QueryRewriter

local DEFAULT_LIMIT = 10

--- Creates a new QueryRewriter.
-- @param connection_name string  Exasol CONNECTION name pointing at Qdrant
--                                (passed through to SEARCH_QDRANT_LOCAL).
function QueryRewriter:new(connection_name)
    return setmetatable({
        _connection_name = connection_name,
    }, self)
end

--- Rewrites a push-down request to a SQL string.
function QueryRewriter:rewrite(request)
    local collection = self:_extract_collection(request)
    local query_text, unsupported = self:_extract_query_text(request)
    local limit      = self:_extract_limit(request)

    if query_text == nil or query_text == "" then
        return self:_build_empty_query_hint(collection, unsupported)
    end

    return self:_build_search_sql(collection, query_text, limit)
end

-- ─────────────────────────────────────────────
-- Request parsing helpers

function QueryRewriter:_extract_collection(request)
    local tables = request.involvedTables or {}
    if not tables[1] then
        error("pushDown request contains no involved tables")
    end
    return tables[1].name:lower()
end

function QueryRewriter:_extract_query_text(request)
    local push = request.pushdownRequest or {}
    if not push.filter then return "", false end
    if push.filter.type == "predicate_equal" then
        local left  = push.filter.left  or {}
        local right = push.filter.right or {}
        if left.type == "column" and left.name and left.name:upper() == "QUERY"
           and right.type == "literal_string" then
            return right.value, false
        end
        if right.type == "column" and right.name and right.name:upper() == "QUERY"
           and left.type == "literal_string" then
            return left.value, false
        end
        return "", true
    end
    return "", true
end

function QueryRewriter:_extract_limit(request)
    local push = request.pushdownRequest or {}
    if push.limit and push.limit.numElements then
        return tonumber(push.limit.numElements) or DEFAULT_LIMIT
    end
    return DEFAULT_LIMIT
end

-- ─────────────────────────────────────────────
-- SQL builders

local function sql_escape(s)
    return (s or ""):gsub("'", "''")
end

--- Returns a single-row hint when no supported QUERY predicate was provided.
function QueryRewriter:_build_empty_query_hint(collection, unsupported_filter)
    local hint
    if unsupported_filter then
        hint = "Unsupported predicate. Only WHERE \"QUERY\" = 'your search text' is supported."
            .. " LIKE, >, <, AND, OR are not supported."
            .. " Example: SELECT \"ID\", \"TEXT\", \"SCORE\" FROM vector_schema."
            .. collection .. " WHERE \"QUERY\" = 'your search' LIMIT 10"
    else
        hint = "Semantic search requires: WHERE \"QUERY\" = 'your search text'."
            .. " Example: SELECT \"ID\", \"TEXT\", \"SCORE\" FROM vector_schema."
            .. collection .. " WHERE \"QUERY\" = 'your search' LIMIT 10"
    end
    hint = sql_escape(hint)
    local query_hint = sql_escape(
        "Only equality predicates on QUERY are supported: WHERE \"QUERY\" = 'your text'")
    return "SELECT * FROM VALUES"
        .. " (CAST('HINT' AS VARCHAR(2000000) UTF8),"
        .. " CAST('" .. hint .. "' AS VARCHAR(2000000) UTF8),"
        .. " CAST(1 AS DOUBLE),"
        .. " CAST('" .. query_hint .. "' AS VARCHAR(2000000) UTF8))"
        .. " AS t(ID, TEXT, SCORE, QUERY)"
end

--- Generates the SET-UDF call wrapped to expose the (ID, TEXT, SCORE, QUERY)
-- column projection the virtual schema declares.
function QueryRewriter:_build_search_sql(collection, query_text, limit)
    return string.format(
        "SELECT result_id AS \"ID\", result_text AS \"TEXT\","
        .. " result_score AS \"SCORE\", result_query AS \"QUERY\""
        .. " FROM (SELECT ADAPTER.SEARCH_QDRANT_LOCAL("
        .. "'%s', '%s', '%s', %d) FROM DUAL)",
        sql_escape(self._connection_name),
        sql_escape(collection),
        sql_escape(query_text),
        limit
    )
end

return QueryRewriter
