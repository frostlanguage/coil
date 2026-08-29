-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Reject duplicated tool identities outside toolchain.lock.toml.

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
   io.stderr:write("coil check-toolchain: error: " .. message .. "\n")
   os.exit(1)
end

--- Read one repository-relative UTF-8 text file.
-- @param path string: repository-relative path.
-- @return string: file contents.
local function read_file(path)
   local handle = io.open(paths.join(repo_root, path), "rb")
   if handle == nil then
      fail("cannot open tracked file '" .. path .. "'.")
   end

   local content = handle:read("*a")
   handle:close()

   if content == nil then
      fail("cannot read tracked file '" .. path .. "'.")
   end

   return content
end

--- Check whether a workflow line defines a tool identity directly.
-- @param line string: YAML source line.
-- @return boolean: true when the line is a forbidden hardcoded identity.
local function hardcoded_identity(line)
   local key, value = line:match("^%s+([A-Z][A-Z0-9_]+):%s*(.+)$")

   if key == nil or value == nil then
      return false
   end

   local identity = key:match("_VERSION$") ~= nil
      or key:match("_SHA256$") ~= nil
      or key:match("_REVISION$") ~= nil

   if not identity then
      return false
   end

   value = value:match("^%s*(.-)%s*$") or value

   if value:find("${{", 1, true) ~= nil then
      return false
   end

   if value:find("${", 1, true) == 1 then
      return false
   end

   return true
end

local tracked = git.tracked_files()
if type(tracked) ~= "table" then
   fail("git ls-files failed.")
end

local violations = {}

for _, path in ipairs(tracked) do
   local workflow = path:match("^%.github/") ~= nil
      and (paths.ends_with(path, ".yml") or paths.ends_with(path, ".yaml"))

   if workflow then
      local content = read_file(path)
      local line_number = 0

      for line in (content .. "\n"):gmatch("(.-)\n") do
         line_number = line_number + 1

         if hardcoded_identity(line) then
            violations[#violations + 1] = string.format(
               "%s:%d: %s",
               path,
               line_number,
               line:match("^%s*(.-)%s*$") or line
            )
         end
      end
   end
end

if #violations > 0 then
   io.stderr:write("toolchain lock authority violations:\n")
   for _, violation in ipairs(violations) do
      io.stderr:write("  " .. violation .. "\n")
   end
   os.exit(1)
end

print("toolchain.lock.toml is the only workflow tool identity source.")

-- EOF
