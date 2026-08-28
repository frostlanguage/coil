-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Generic Git helpers for Lua tooling.
-- The module is dependency-injected with scripts/libs/platform.lua.

local M = {}

--- Create a Git helper bound to one platform implementation.
-- @param platform table: process helper module.
-- @param repository string|nil: repository working tree for git -C.
-- @return table: Git helper methods.
function M.new(platform, repository)
   assert(type(platform) == "table", "platform module is required")

   local prefix = { "git" }
   if repository and repository ~= "" then
      prefix[#prefix + 1] = "-C"
      prefix[#prefix + 1] = repository
   end

   local git = {}

   --- Capture stdout from Git.
   -- @param arguments table: Git arguments excluding the executable.
   -- @return string|nil: stdout, or nil when Git fails.
   function git.output(arguments)
      local command = {}
      for _, value in ipairs(prefix) do
         command[#command + 1] = value
      end
      for _, value in ipairs(arguments) do
         command[#command + 1] = value
      end
      return platform.command_output(command)
   end

   --- Resolve the repository root directory.
   -- @return string|nil: repository root, or nil on failure.
   function git.root()
      local output = git.output({ "rev-parse", "--show-toplevel" })
      if not output then
         return nil
      end

      output = output:gsub("%s+$", "")
      if output == "" then
         return nil
      end

      return output
   end

   --- Resolve one revision to its object identifier.
   -- @param revision string: revision expression.
   -- @return string|nil: resolved object identifier, or nil on failure.
   function git.resolve(revision)
      local output = git.output({ "rev-parse", "--verify", revision })
      if not output then
         return nil
      end

      output = output:gsub("%s+$", "")
      if output == "" then
         return nil
      end

      return output
   end

   --- Resolve the first parent of a revision.
   -- @param revision string: revision expression.
   -- @return string|nil: parent object identifier, or nil when unavailable.
   function git.parent(revision)
      return git.resolve(revision .. "^")
   end

   --- Collect tracked repository paths using NUL delimiters.
   -- @return table|nil: sorted paths, or nil when Git fails.
   function git.tracked_files()
      local output = git.output({ "ls-files", "-z" })
      if output == nil then
         return nil
      end

      local files = {}
      for path in output:gmatch("([^%z]+)") do
         files[#files + 1] = path
      end

      table.sort(files)
      return files
   end

   --- Collect changed paths between two revisions using NUL delimiters.
   -- @param base string: base revision.
   -- @param head string: head revision.
   -- @return table|nil: changed paths, or nil when Git diff fails.
   function git.changed_files(base, head)
      local output = git.output({
         "diff",
         "--name-only",
         "-z",
         base,
         head,
      })

      if output == nil then
         return nil
      end

      local files = {}
      for path in output:gmatch("([^%z]+)") do
         files[#files + 1] = path
      end

      return files
   end

   return git
end

--- Check whether a revision consists only of zeroes.
-- @param revision string: Git revision text.
-- @return boolean: true for Git's all-zero sentinel.
function M.zero_revision(revision)
   return revision ~= "" and revision:match("^0+$") ~= nil
end

return M

-- EOF
