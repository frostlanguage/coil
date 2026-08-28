-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Run the repository Lua quality policy locally or in CI.
-- Tool paths may be overridden through COIL_* environment variables.

local raw_script = tostring(arg[0] or ""):gsub("\\", "/")
local script_dir = raw_script:match("^(.*)/[^/]+$") or "scripts/ci"
local scripts_root = script_dir:match("^(.*)/ci$") or "scripts"
local repo_root = scripts_root:match("^(.*)/scripts$") or "."
local library_root = scripts_root .. "/libs"
local paths = dofile(library_root .. "/paths.lua")
local platform = dofile(paths.join(library_root, "platform.lua"))
local git_module = dofile(paths.join(library_root, "git.lua"))
local git = git_module.new(platform, repo_root)

--- Print a fatal diagnostic and terminate.
-- @param message string: diagnostic text.
local function fail(message)
   io.stderr:write("coil check-lua: error: " .. message .. "\n")
   os.exit(1)
end

--- Read the first line of a file.
-- @param path string: file path.
-- @return string: first line or an empty string.
local function first_line(path)
   local file = io.open(paths.join(repo_root, path), "rb")
   if not file then
      return ""
   end

   local line = file:read("*l") or ""
   file:close()
   return line
end

--- Check whether a tracked file contains Lua source.
-- @param path string: repository-relative path.
-- @return boolean: true for Lua source files and Lua shebang programs.
local function is_lua_source(path)
   if paths.ends_with(path, ".lua") then
      return true
   end

   local line = first_line(path)
   return line:match("^#!.*lua([%s/].*)?$") ~= nil
end

--- Resolve one required executable.
-- @param variable string: environment variable override.
-- @param default_name string: default executable name.
-- @return string: executable to invoke.
local function tool(variable, default_name)
   local executable = platform.resolve_tool(variable, default_name)
   if not executable then
      fail(
         "required tool '"
            .. default_name
            .. "' is unavailable; set "
            .. variable
            .. "."
      )
   end
   return executable
end

--- Execute one command and convert library errors into stable diagnostics.
-- @param arguments table: command arguments.
local function run(arguments)
   local ok, message = pcall(platform.run_in_directory, repo_root, arguments)
   if not ok then
      fail(message)
   end
end

--- Run one command over files in bounded argv batches.
-- @param prefix table: command and fixed arguments.
-- @param files table: paths to append.
local function run_batched(prefix, files)
   local ok, message =
      pcall(platform.run_batched_in_directory, repo_root, prefix, files, 64)
   if not ok then
      fail(message)
   end
end

local tracked = git.tracked_files()
if type(tracked) ~= "table" then
   fail("git ls-files failed.")
end

local files = {}
assert(type(tracked) == "table")
for _, path in ipairs(tracked) do
   if is_lua_source(path) then
      files[#files + 1] = path
   end
end

if #files == 0 then
   print("No tracked Lua sources found.")
   os.exit(0)
end

local lua = tool("COIL_LUA", "lua")
local luac = tool("COIL_LUAC", "luac")
local selene = tool("COIL_SELENE", "selene")
local stylua = tool("COIL_STYLUA", "stylua")
local luals = tool("COIL_LUALS", "lua-language-server")
local root = git.root()

if not root then
   fail("cannot resolve the repository root.")
end

print(string.format("Checking %d Lua source file(s).", #files))

run_batched({ luac, "-p" }, files)

run({
   lua,
   "tools/lint/spell/dictionary/generate.lua",
   "--check",
})

run_batched({
   selene,
   "--config",
   "tools/lint/code/lua/selene.toml",
}, files)

run_batched({
   stylua,
   "--check",
   "--config-path",
   "tools/lint/code/lua/stylua.toml",
}, files)

run({
   luals,
   "--configpath=tools/lint/code/lua/luals.json",
   "--check=" .. root,
   "--checklevel=Warning",
})

-- EOF
