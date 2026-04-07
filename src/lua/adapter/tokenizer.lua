--- Tokenizer: extracts meaningful keywords from query text for hybrid search.
-- Pure Lua, no external dependencies. Used by QueryRewriter to build
-- Qdrant keyword filters alongside vector search.

local M = {}

-- Common English stopwords — removed during tokenization.
local STOP = {}
for _, w in ipairs({
    "a","an","the","and","or","but","not","no","nor","so","yet",
    "is","am","are","was","were","be","been","being",
    "has","have","had","do","does","did","will","would","shall","should",
    "can","could","may","might","must",
    "in","on","at","to","for","of","by","from","with","about","between",
    "through","during","before","after","above","below","up","down",
    "out","off","over","under","into",
    "i","me","my","we","us","our","you","your","he","him","his",
    "she","her","it","its","they","them","their",
    "this","that","these","those","what","which","who","whom","how",
    "when","where","why","if","then","than","as","while",
    "all","each","every","both","few","more","most","some","any","such",
    "very","just","also","only","too","own","same","other",
}) do STOP[w] = true end

--- Tokenize a query string into meaningful keywords.
-- Splits on non-alphanumeric, lowercases, removes stopwords and
-- tokens shorter than 2 chars. Also generates compound tokens by
-- concatenating adjacent non-stopword pairs (e.g., "JP" + "Morgan"
-- produces "jpmorgan") to match camelCase/concatenated terms in source data.
-- Returns a deduplicated array, capped at 12 tokens.
-- @param text string  The user's query
-- @return table  Array of keyword strings (may be empty)
function M.extract_keywords(text)
    local seen = {}
    local result = {}
    local prev = nil

    for word in text:lower():gmatch("[%w]+") do
        if #word >= 2 and not STOP[word] and not seen[word] then
            seen[word] = true
            result[#result + 1] = word

            -- Generate compound token from adjacent non-stopword pairs
            if prev then
                local compound = prev .. word
                if not seen[compound] then
                    seen[compound] = true
                    result[#result + 1] = compound
                end
            end
            prev = word
        else
            prev = nil
        end
    end

    -- Cap at 12 tokens to limit prefetch legs
    if #result > 12 then
        local capped = {}
        for i = 1, 12 do capped[i] = result[i] end
        return capped
    end
    return result
end

return M
