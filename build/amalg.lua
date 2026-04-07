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

local repo_root = arg and arg[0] and arg[0]:match("(.+)/[^/]+$") .. "/.." or "."
repo_root = repo_root:gsub("\\", "/")

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
    "adapter.tokenizer",
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

-- Detect LuaRocks share path automatically via `luarocks path`
local rocks_share
local lr = io.popen("luarocks path --lr-path 2>/dev/null")
if lr then
    local lr_path = lr:read("*a"):match("^([^\n;]+)")
    lr:close()
    if lr_path then
        rocks_share = lr_path:match("^(.+)/[^/]+$")
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

local args = {
    "amalg.lua",
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
