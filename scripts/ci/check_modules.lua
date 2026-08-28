-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Local entrypoint for Coil module-architecture validation.
-- Semantic CMOD enforcement is intentionally delegated until its checker is
-- defined.

local raw_script = tostring(arg[0] or ""):gsub("\\", "/")
local script_dir = raw_script:match("^(.*)/[^/]+$") or "scripts/ci"
local scripts_root = script_dir:match("^(.*)/ci$") or "scripts"
local repo_root = scripts_root:match("^(.*)/scripts$") or "."
local library_root = scripts_root .. "/libs"
local paths = dofile(library_root .. "/paths.lua")
local platform = dofile(paths.join(library_root, "platform.lua"))
local git_module = dofile(paths.join(library_root, "git.lua"))
local git = git_module.new(platform, repo_root)

local architecture_policy =
   "docs/code_style/c_language/c-module-architecture.md"

--- Print a fatal diagnostic and terminate.
-- @param message string: diagnostic text.
local function fail(message)
   io.stderr:write("coil check-modules: error: " .. message .. "\n")
   os.exit(1)
end

local policy_file = io.open(paths.join(repo_root, architecture_policy), "rb")
if policy_file == nil then
   fail("module architecture policy is missing: " .. architecture_policy)
else
   policy_file:close()
end

local tracked = git.tracked_files()
if type(tracked) ~= "table" then
   fail("git ls-files failed.")
end

local translation_units = {}
assert(type(tracked) == "table")
for _, path in ipairs(tracked) do
   if paths.ends_with(path, ".c") or paths.ends_with(path, ".i") then
      translation_units[#translation_units + 1] = path
   end
end

if #translation_units == 0 then
   print(
      "No tracked C translation units found; "
         .. "module policy entrypoint is ready."
   )
   os.exit(0)
end

local checker = os.getenv("COIL_MODULE_CHECKER")
if not checker or checker == "" then
   fail(
      "tracked C translation units exist, but "
         .. "COIL_MODULE_CHECKER is not configured."
   )
end

local arguments = { checker }
for _, source in ipairs(translation_units) do
   arguments[#arguments + 1] = source
end

local ok, message = pcall(platform.run_in_directory, repo_root, arguments)
if not ok then
   fail(message)
end

-- EOF
