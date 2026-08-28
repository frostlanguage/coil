-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Run the repository C formatting and clang-tidy policy locally or in CI.
-- Tool paths may be overridden through COIL_CLANG_FORMAT and COIL_CLANG_TIDY.

local raw_script = tostring(arg[0] or ""):gsub("\\", "/")
local script_dir = raw_script:match("^(.*)/[^/]+$") or "scripts/ci"
local scripts_root = script_dir:match("^(.*)/ci$") or "scripts"
local repo_root = scripts_root:match("^(.*)/scripts$") or "."
local library_root = scripts_root .. "/libs"
local paths = dofile(library_root .. "/paths.lua")
local platform = dofile(paths.join(library_root, "platform.lua"))
local git_module = dofile(paths.join(library_root, "git.lua"))
local git = git_module.new(platform, repo_root)

local format_config = "tools/lint/code/c/.clang-format"
local tidy_config = "tools/lint/code/c/.clang-tidy"

--- Print a fatal diagnostic and terminate.
-- @param message string: diagnostic text.
local function fail(message)
   io.stderr:write("coil check-c: error: " .. message .. "\n")
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

local clang_format = tool("COIL_CLANG_FORMAT", "clang-format")
local clang_tidy = tool("COIL_CLANG_TIDY", "clang-tidy")

if
   not platform.command_succeeded_silent_in_directory(repo_root, {
      clang_format,
      "--style=file:" .. format_config,
      "--dump-config",
   })
then
   fail("clang-format configuration is invalid.")
end

if
   not platform.command_succeeded_silent_in_directory(repo_root, {
      clang_tidy,
      "--experimental-custom-checks",
      "--config-file=" .. tidy_config,
      "--list-checks",
   })
then
   fail("clang-tidy configuration is invalid.")
end

local tracked = git.tracked_files()
if tracked == nil then
   fail("git ls-files failed.")
end

local format_files = {}
local translation_units = {}

for _, path in ipairs(tracked) do
   if
      paths.ends_with(path, ".c")
      or paths.ends_with(path, ".h")
      or paths.ends_with(path, ".i")
   then
      format_files[#format_files + 1] = path
   end

   if paths.ends_with(path, ".c") or paths.ends_with(path, ".i") then
      translation_units[#translation_units + 1] = path
   end
end

if #format_files == 0 then
   print("No tracked C sources or headers found; policy files are valid.")
   os.exit(0)
end

print(string.format("Checking %d C source/header file(s).", #format_files))

run_batched({
   clang_format,
   "--style=file:" .. format_config,
   "--dry-run",
   "--Werror",
}, format_files)

for _, source in ipairs(translation_units) do
   run({
      clang_tidy,
      "--experimental-custom-checks",
      "--config-file=" .. tidy_config,
      source,
      "--",
      "-std=c23",
      "-I.",
   })
end

-- EOF
