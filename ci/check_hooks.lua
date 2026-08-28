-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Run Coil Git-hook parser checks and mock suites locally or in CI.

local raw_script = tostring(arg[0] or ""):gsub("\\", "/")
local scripts_root = raw_script:match("^(.*)/ci/[^/]+$") or "scripts"
local paths = dofile(scripts_root .. "/libs/paths.lua")
local platform = dofile(paths.join(scripts_root, "libs", "platform.lua"))
local repo_root = paths.dirname(scripts_root)

local sources = {
   ".githooks/commit-msg",
   ".githooks/lib/platform.lua",
   ".githooks/pre-commit",
   ".githooks/pre-push",
   "tests/mock/git_hooks/coil-hook-test-suite.lua",
   "tests/mock/git_hooks/coil-ref-policy-test-suite.lua",
}

local suites = {
   "tests/mock/git_hooks/coil-hook-test-suite.lua",
   "tests/mock/git_hooks/coil-ref-policy-test-suite.lua",
}

--- Print a fatal diagnostic and terminate.
-- @param message string: diagnostic text.
local function fail(message)
   io.stderr:write("coil check-hooks: error: " .. message .. "\n")
   os.exit(1)
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
   local ok, message = pcall(
      platform.run_in_directory,
      repo_root,
      arguments
   )
   if not ok then
      fail(message)
   end
end

local lua = tool("COIL_LUA", "lua")
local luac = tool("COIL_LUAC", "luac")
local parser = { luac, "-p" }

for _, source in ipairs(sources) do
   parser[#parser + 1] = source
end
run(parser)

for _, suite in ipairs(suites) do
   run({ lua, suite })
end

-- EOF
