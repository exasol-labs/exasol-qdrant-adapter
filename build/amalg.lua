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

-- Modules to bundle (everything under src/lua/)
local modules = {
    "adapter.QdrantAdapter",
    "adapter.AdapterProperties",
    "adapter.capabilities",
    "adapter.MetadataReader",
    "adapter.QueryRewriter",
    "util.http",
}

-- Create dist/ if it doesn't exist
os.execute(string.format('mkdir -p "%s"', dist_dir))

-- Build the amalg command.
-- LUA_PATH is set so amalg can resolve both src/lua/ modules and
-- LuaRocks-installed framework modules (virtual-schema-common-lua etc.).
local lua_path = string.format(
    "LUA_PATH='%s/?.lua;;'",
    src_dir
)

local args = {
    "amalg.lua",
    "-o", string.format('"%s"', output),
    "-s", entry,
}
for _, m in ipairs(modules) do
    args[#args + 1] = m
end

local cmd = string.format(
    "cd %q && %s lua %s",
    src_dir,
    lua_path,
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
