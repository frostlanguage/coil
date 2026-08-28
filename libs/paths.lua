-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Generic path helpers shared by Coil Lua tooling.
-- Repository paths are normalized to forward slashes on every host OS.

local M = {}

--- Normalize path separators and redundant separators.
-- @param value string: path to normalize.
-- @return string: normalized path.
function M.normalize(value)
   local path = tostring(value or ""):gsub("\\", "/")
   local unc = path:sub(1, 2) == "//"

   if unc then
      path = path:sub(3)
   end

   path = path:gsub("/+", "/")

   if unc then
      path = "//" .. path
   elseif path:sub(1, 2) == "./" then
      path = path:sub(3)
   end

   local drive_root = path:match("^%a:/$") ~= nil
   if #path > 1 and path:sub(-1) == "/" and not drive_root then
      path = path:sub(1, -2)
   end

   return path
end

--- Return the directory component of a path.
-- @param value string: path to inspect.
-- @return string: parent directory or '.'.
function M.dirname(value)
   local path = M.normalize(value)
   local parent = path:match("^(.*)/[^/]*$")

   if not parent or parent == "" then
      return "."
   end

   return parent
end

--- Join path components with normalized separators.
-- @param ... string: path components.
-- @return string: joined path.
function M.join(...)
   local parts = { ... }
   local result = ""

   for _, part in ipairs(parts) do
      local value = M.normalize(part)
      if value ~= "" and value ~= "." then
         if result == "" then
            result = value
         else
            result = result:gsub("/$", "") .. "/" .. value:gsub("^/", "")
         end
      end
   end

   if result == "" then
      return "."
   end

   return result
end

--- Check whether a path starts with a prefix.
-- @param value string: path to inspect.
-- @param prefix string: normalized prefix.
-- @return boolean: true when the prefix matches.
function M.starts_with(value, prefix)
   local path = M.normalize(value)
   local expected = M.normalize(prefix)
   return path:sub(1, #expected) == expected
end

--- Check whether a string ends with a suffix.
-- @param value string: string to inspect.
-- @param suffix string: suffix to find.
-- @return boolean: true when the suffix matches.
function M.ends_with(value, suffix)
   local text = tostring(value or "")
   local expected = tostring(suffix or "")

   if expected == "" then
      return true
   end

   return text:sub(-#expected) == expected
end

--- Resolve the scripts directory from one scripts/ci entrypoint path.
-- @param script_path string: arg[0] from a CI script.
-- @return string: path to the scripts directory.
function M.scripts_root(script_path)
   local path = M.normalize(script_path)
   return path:match("^(.*)/ci/[^/]+$") or "scripts"
end

return M

-- EOF
