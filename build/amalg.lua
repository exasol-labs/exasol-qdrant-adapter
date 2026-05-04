#!/usr/bin/env lua
--- Build script: bundles src/lua/ into dist/adapter.lua using lua-amalg.
--
-- Prerequisites:
--   luarocks install amalg
--   luarocks install virtual-schema-common-lua
--
-- Usage (from repo root):
--   lua build/amalg.lua
--
-- Output:
--   dist/adapter.lua  — single-file adapter, ready for CREATE LUA ADAPTER SCRIPT

-- Anchor on this script's location, then resolve to the absolute repo root
-- (parent of build/). We need an absolute path because the inner amalg
-- invocation runs with cwd=src/lua/, and any relative output path would be
-- resolved relative to *that*, not the repo root.
local script_dir = arg and arg[0] and arg[0]:match("(.+)/[^/]+$") or "."
script_dir = script_dir:gsub("\\", "/")
local repo_root = script_dir .. "/.."

-- Convert to absolute (works on both Windows cmd.exe and POSIX shells).
local cwd_h = io.popen(package.config:sub(1,1) == "\\" and "cd" or "pwd")
if cwd_h then
    local cwd = (cwd_h:read("*l") or "."):gsub("\\", "/")
    cwd_h:close()
    if not repo_root:match("^[A-Za-z]:/") and not repo_root:match("^/") then
        repo_root = cwd .. "/" .. repo_root
    end
end

local src_dir  = repo_root .. "/src/lua"
local dist_dir = repo_root .. "/dist"
local output   = dist_dir .. "/adapter.lua"
local entry    = "entry.lua"

-- Modules to bundle: adapter code (src/lua/) + framework dependencies.
-- The vscl / ExaError / remotelog modules are bundled so the adapter is
-- fully self-contained — no assumption about what the Exasol Lua runtime
-- ships. package.preload takes priority, so pre-installed copies are
-- harmlessly shadowed.
local modules = {
    -- Adapter modules (src/lua/)
    "adapter.QdrantAdapter",
    "adapter.AdapterProperties",
    "adapter.capabilities",
    "adapter.MetadataReader",
    "adapter.QueryRewriter",
    "util.http",
    -- virtual-schema-common-lua (vscl)
    "exasol.vscl.AbstractVirtualSchemaAdapter",
    "exasol.vscl.AdapterProperties",
    "exasol.vscl.RequestDispatcher",
    "exasol.vscl.text",
    "exasol.vscl.Query",
    "exasol.vscl.QueryRenderer",
    "exasol.vscl.ImportQueryBuilder",
    "exasol.vscl.validator",
    "exasol.vscl.queryrenderer.AbstractQueryAppender",
    "exasol.vscl.queryrenderer.AggregateFunctionAppender",
    "exasol.vscl.queryrenderer.ExpressionAppender",
    "exasol.vscl.queryrenderer.ImportAppender",
    "exasol.vscl.queryrenderer.ScalarFunctionAppender",
    "exasol.vscl.queryrenderer.SelectAppender",
    -- vscl external dependencies
    "ExaError",
    "MessageExpander",
    "remotelog",
}

-- Create dist/ if it doesn't exist
os.execute(string.format('mkdir -p "%s" 2>%s', dist_dir,
    package.config:sub(1,1) == "\\" and "NUL" or "/dev/null"))

-- Detect LuaRocks share path automatically via `luarocks path --lr-path`.
-- That call returns one or more path entries like
--   .../rocks/share/lua/5.4/?.lua;.../rocks/share/lua/5.4/?/init.lua
-- We strip the `?.lua` / `?/init.lua` suffix to get the share directory,
-- since amalg.lua lives directly inside it.
local rocks_share
local null_redirect = package.config:sub(1,1) == "\\" and "2>NUL" or "2>/dev/null"
local lr = io.popen("luarocks path --lr-path " .. null_redirect)
if lr then
    local raw = lr:read("*a") or ""
    lr:close()
    for entry in raw:gmatch("[^;\n]+") do
        local cand = entry:gsub("\\", "/")
        cand = cand:gsub("/%?/init%.lua$", ""):gsub("/%?%.lua$", "")
        if cand ~= "" and cand:match("rocks/share/lua/[%d%.]+$") then
            rocks_share = cand
            break
        end
    end
end
rocks_share = rocks_share
    or os.getenv("LUAROCKS_SHARE")
    or (os.getenv("HOME") or os.getenv("USERPROFILE") or "") .. "/.luarocks/share/lua/5.4"

-- Build LUA_PATH covering src/lua/ and LuaRocks-installed dependencies.
local lua_path = string.format("%s/?.lua;%s/?.lua;%s/?/init.lua;;",
    src_dir, rocks_share, rocks_share)

-- Set it directly so the child process inherits it via package.path.
package.path = lua_path

-- amalg ships as a Lua script inside the rocks share dir. We pass its full
-- path so the inner `lua` invocation can find it without depending on the
-- current working directory.
local amalg_script = rocks_share .. "/amalg.lua"
local args = {
    string.format('"%s"', amalg_script),
    "-o", string.format('"%s"', output),
    "-s", entry,
}
for _, m in ipairs(modules) do
    args[#args + 1] = m
end

-- Cross-platform: set LUA_PATH as an env var before invoking amalg.
local is_windows = package.config:sub(1,1) == "\\"
local env_prefix
if is_windows then
    env_prefix = string.format('set "LUA_PATH=%s" && ', lua_path)
else
    env_prefix = string.format("LUA_PATH='%s' ", lua_path)
end

local cmd = string.format(
    "cd %q && %slua %s",
    src_dir,
    env_prefix,
    table.concat(args, " ")
)

print("Building: " .. output)
print("Command:  " .. cmd)

local ok = os.execute(cmd)
if ok == true or ok == 0 then
    print("Done: dist/adapter.lua")
else
    error("Build failed — check that lua-amalg is installed (luarocks install amalg)")
end
