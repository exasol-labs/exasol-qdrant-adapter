-- Exasol's built-in require() ignores package.preload. Patch it so that
-- amalg-bundled modules are found before falling back to the original loader.
local _original_require = require
require = function(modname)
    if package.loaded[modname] then return package.loaded[modname] end
    local preload_fn = package.preload[modname]
    if preload_fn then
        local ok, result = pcall(preload_fn, modname)
        if not ok then
            error("Failed loading bundled module [" .. modname .. "]: " .. tostring(result), 2)
        end
        package.loaded[modname] = result == nil and true or result
        return package.loaded[modname]
    end
    return _original_require(modname)
end
