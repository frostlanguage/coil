-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Cross-platform process helpers for Lua tooling.
-- Keep host-shell quoting and command discovery isolated in this module.

local M = {}

M.is_windows = os.getenv("OS") == "Windows_NT"
M.null_device = M.is_windows and "NUL" or "/dev/null"

--- Normalize Lua process-status return values.
-- @param first boolean|number|nil: first status value.
-- @param code number|nil: process exit code when available.
-- @return boolean: true only for a successful process exit.
local function process_succeeded(first, code)
   if type(first) == "number" then
      return first == 0
   end

   if first == true then
      return true
   end

   return code == 0
end

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

--- Join an argv-style table into one host-shell command.
-- @param arguments table: command arguments.
-- @return string: quoted command string.
function M.join_command(arguments)
   local quoted = {}

   for index, value in ipairs(arguments) do
      quoted[index] = M.shell_quote(value)
   end

   return table.concat(quoted, " ")
end

--- Build a command that executes from one working directory.
-- @param directory string: working directory.
-- @param arguments table|string: argv table or complete command string.
-- @return string: host-shell command.
function M.in_directory(directory, arguments)
   local command = arguments
   if type(arguments) == "table" then
      command = M.join_command(arguments)
   end

   if M.is_windows then
      return "cd /d " .. M.shell_quote(directory) .. " && " .. command
   end

   return "cd " .. M.shell_quote(directory) .. " && " .. command
end

--- Run a command and report whether it completed successfully.
-- @param arguments table|string: argv table or complete command string.
-- @return boolean: true when the command exits with status zero.
function M.command_succeeded(arguments)
   local command = arguments
   if type(arguments) == "table" then
      command = M.join_command(arguments)
   end

   local first, _, code = os.execute(command)
   return process_succeeded(first, code)
end

--- Capture stdout from a command and fail closed on non-zero exit status.
-- @param arguments table|string: argv table or complete command string.
-- @return string|nil: stdout, or nil when the command fails.
function M.command_output(arguments)
   local command = arguments
   if type(arguments) == "table" then
      command = M.join_command(arguments)
   end

   local handle = io.popen(command, "r")
   if not handle then
      return nil
   end

   local output = handle:read("*a")
   local first, _, code = handle:close()

   if not process_succeeded(first, code) then
      return nil
   end

   return output
end

--- Append host-native stdout and stderr redirection to the null device.
-- @param command string: command string.
-- @return string: command with all output suppressed.
function M.silence_all(command)
   local null = M.shell_quote(M.null_device)
   return command .. " >" .. null .. " 2>&1"
end

--- Run a command while discarding stdout and stderr.
-- @param arguments table|string: argv table or complete command string.
-- @return boolean: true when the command exits with status zero.
function M.command_succeeded_silent(arguments)
   local command = arguments
   if type(arguments) == "table" then
      command = M.join_command(arguments)
   end

   return M.command_succeeded(M.silence_all(command))
end

--- Run a command from one directory and report success.
-- @param directory string: working directory.
-- @param arguments table|string: argv table or complete command string.
-- @return boolean: true when the command exits with status zero.
function M.command_succeeded_in_directory(directory, arguments)
   return M.command_succeeded(M.in_directory(directory, arguments))
end

--- Capture stdout from a command executed from one directory.
-- @param directory string: working directory.
-- @param arguments table|string: argv table or complete command string.
-- @return string|nil: stdout, or nil when the command fails.
function M.command_output_in_directory(directory, arguments)
   return M.command_output(M.in_directory(directory, arguments))
end

--- Run a command silently from one directory.
-- @param directory string: working directory.
-- @param arguments table|string: argv table or complete command string.
-- @return boolean: true when the command exits with status zero.
function M.command_succeeded_silent_in_directory(directory, arguments)
   local command = M.in_directory(directory, arguments)
   return M.command_succeeded(M.silence_all(command))
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

--- Resolve a required executable from an environment override or PATH.
-- @param variable string: environment variable override.
-- @param default_name string: executable name used when no override exists.
-- @return string|nil: executable path/name, or nil when unavailable.
function M.resolve_tool(variable, default_name)
   local value = os.getenv(variable)
   if value and value ~= "" then
      return value
   end

   if M.command_exists(default_name) then
      return default_name
   end

   return nil
end

--- Run one argv table and raise a Lua error on failure.
-- @param arguments table: command arguments.
function M.run(arguments)
   if not M.command_succeeded(arguments) then
      error("command failed: " .. M.join_command(arguments), 2)
   end
end

--- Run one argv table from a working directory and raise on failure.
-- @param directory string: working directory.
-- @param arguments table: command arguments.
function M.run_in_directory(directory, arguments)
   if not M.command_succeeded_in_directory(directory, arguments) then
      error(
         "command failed: "
            .. M.in_directory(directory, arguments),
         2
      )
   end
end

--- Run a command over paths in bounded argv batches.
-- @param prefix table: command and fixed arguments.
-- @param values table: arguments to append.
-- @param batch_size number|nil: maximum appended values per invocation.
function M.run_batched(prefix, values, batch_size)
   local limit = batch_size or 64
   local first = 1

   while first <= #values do
      local arguments = {}
      for _, value in ipairs(prefix) do
         arguments[#arguments + 1] = value
      end

      local last = math.min(first + limit - 1, #values)
      for index = first, last do
         arguments[#arguments + 1] = values[index]
      end

      M.run(arguments)
      first = last + 1
   end
end

--- Run a command over values in bounded batches from one directory.
-- @param directory string: working directory.
-- @param prefix table: command and fixed arguments.
-- @param values table: arguments to append.
-- @param batch_size number|nil: maximum appended values per invocation.
function M.run_batched_in_directory(directory, prefix, values, batch_size)
   local limit = batch_size or 64
   local first = 1

   while first <= #values do
      local arguments = {}
      for _, value in ipairs(prefix) do
         arguments[#arguments + 1] = value
      end

      local last = math.min(first + limit - 1, #values)
      for index = first, last do
         arguments[#arguments + 1] = values[index]
      end

      M.run_in_directory(directory, arguments)
      first = last + 1
   end
end

return M

-- EOF
