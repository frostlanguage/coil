-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Cross-platform process helpers for Coil Git hooks.
-- The hooks may be executed by a POSIX shell or native Windows cmd.exe.
-- Keep shell-specific quoting, null devices, and command discovery here.

local M = {}

M.is_windows = os.getenv("OS") == "Windows_NT"
M.null_device = M.is_windows and "NUL" or "/dev/null"

--- Quote one argument for the host command processor.
-- @param value string: argument to quote.
-- @return string: quoted argument.
function M.shell_quote(value)
   value = tostring(value)

   if M.is_windows then
      value = value:gsub("%%", "%%%%")
      value = value:gsub('"', '\\"')
      return '"' .. value .. '"'
   end

   return "'" .. value:gsub("'", "'\\''") .. "'"
end

--- Run one shell command and report whether it succeeded.
-- @param command string: command string.
-- @return boolean: true for exit status zero.
function M.command_succeeded(command)
   local first, _, code = os.execute(command)

   if type(first) == "number" then
      return first == 0
   end

   if first == true then
      return true
   end

   return code == 0
end

--- Capture stdout from one shell command.
-- @param command string: command string.
-- @return string|nil: command stdout, or nil if spawning failed.
function M.command_output(command)
   local handle = io.popen(command, "r")

   if not handle then
      return nil
   end

   local output = handle:read("*a")
   handle:close()

   return output
end

--- Append a host-native stderr redirection to the null device.
-- @param command string: command string.
-- @return string: command with stderr suppressed.
function M.silence_stderr(command)
   return command .. " 2>" .. M.shell_quote(M.null_device)
end

--- Append host-native stdout and stderr redirection to the null device.
-- @param command string: command string.
-- @return string: command with all output suppressed.
function M.silence_all(command)
   return command .. " >" .. M.shell_quote(M.null_device) .. " 2>&1"
end

--- Return only a stderr redirection fragment.
-- @return string: host-native redirection fragment.
function M.stderr_redirect()
   return "2>" .. M.shell_quote(M.null_device)
end

--- Return a stdout and stderr redirection fragment.
-- @return string: host-native redirection fragment.
function M.all_redirect()
   return ">" .. M.shell_quote(M.null_device) .. " 2>&1"
end

--- Check whether an executable is available through PATH.
-- @param name string: executable name.
-- @return boolean: true when resolvable.
function M.command_exists(name)
   local probe

   if M.is_windows then
      probe = "where.exe " .. M.shell_quote(name)
   else
      probe = "command -v " .. M.shell_quote(name)
   end

   return M.command_succeeded(M.silence_all(probe))
end

--- Check whether a path is absolute on the current host.
-- @param path string: path to inspect.
-- @return boolean: true for an absolute path.
function M.is_absolute_path(path)
   if M.is_windows then
      return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
   end

   return path:sub(1, 1) == "/"
end

--- Return the directory component of a path using either separator style.
-- @param path string: path to inspect.
-- @return string|nil: directory component.
function M.dirname(path)
   return path:match("^(.*)[/\\][^/\\]+$")
end

return M
