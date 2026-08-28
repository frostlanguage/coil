-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Classify changed repository paths for selective CI execution.
-- Full validation can be forced for trusted integration and release events.

local raw_script = tostring(arg[0] or ""):gsub("\\", "/")
local script_dir = raw_script:match("^(.*)/[^/]+$") or "."
local repo_root = "."

if script_dir == "ci" then
   repo_root = "."
elseif script_dir:sub(-3) == "/ci" then
   repo_root = script_dir:sub(1, -4)
end

local library_root = repo_root == "." and "libs" or repo_root .. "/libs"
local paths = dofile(library_root .. "/paths.lua")
local platform = dofile(paths.join(library_root, "platform.lua"))
local git_module = dofile(paths.join(library_root, "git.lua"))
local policy = dofile(paths.join(library_root, "policy.lua"))
local git = git_module.new(platform, repo_root)

local categories = {
   "actions",
   "bazel",
   "c",
   "ci",
   "hooks",
   "json",
   "lua",
   "markdown",
   "nushell",
   "powershell",
   "python",
   "security",
   "shell",
   "spelling",
   "toml",
   "yaml",
}

local changed = policy.new(categories)

--- Print a fatal diagnostic and terminate.
-- @param message string: diagnostic text.
local function fail(message)
   io.stderr:write("coil changed-areas: error: " .. message .. "\n")
   os.exit(1)
end

--- Parse command-line options.
-- @return string: base revision.
-- @return string: head revision.
-- @return boolean: whether every category must run.
local function parse_arguments()
   local base = ""
   local head = "HEAD"
   local force_all = false
   local index = 1

   while index <= #arg do
      local option = arg[index]

      if option == "--base" then
         index = index + 1
         base = arg[index] or fail("--base requires a value.")
      elseif option == "--head" then
         index = index + 1
         head = arg[index] or fail("--head requires a value.")
      elseif option == "--force-all" then
         index = index + 1
         local parsed = policy.parse_boolean(arg[index])
         if parsed == nil then
            fail(
               "expected boolean value, got '"
                  .. tostring(arg[index])
                  .. "'."
            )
         end
         force_all = parsed
      else
         fail("unknown option '" .. tostring(option) .. "'.")
      end

      index = index + 1
   end

   return base, head, force_all
end

--- Mark language and policy categories for one changed path.
-- @param input string: repository-relative Git path.
local function classify(input)
   local path = paths.normalize(input)

   if path == ".editorconfig" then
      changed.mark_all()
      return
   end

   if path:match("^%.github/actions/verified%-download/")
      or path:match("^%.github/actions/setup%-lua/")
      or path:match("^libs/")
      or path == "ci/changed_areas.lua"
   then
      changed.mark_all()
      return
   end

   if path:match("^%.github/workflows/") then
      changed.mark("actions")
      changed.mark("ci")
      changed.mark("yaml")
      if path == ".github/workflows/commit-policy.yml" then
         changed.mark("hooks")
      end
   elseif path:match("^%.github/actions/") then
      changed.mark("actions")
      changed.mark("ci")
      changed.mark("yaml")
   end

   if path:match("^ci/") then
      changed.mark("ci")
      changed.mark("lua")

      if path == "ci/check_hooks.lua" then
         changed.mark("hooks")
      elseif path == "ci/check_c.lua"
         or path == "ci/check_modules.lua"
      then
         changed.mark("c")
      end
   end

   if path:match("^%.githooks/") then
      changed.mark("hooks")
      changed.mark("lua")
   end

   if path:match("^tests/mock/git_hooks/") then
      changed.mark("hooks")
      changed.mark("lua")
   end

   if path == ".gitmessage" or path == ".gitconfig" then
      changed.mark("hooks")
   end

   if path:match("^tools/security/") then
      changed.mark("security")
      if path:match("^tools/security/git/") then
         changed.mark("hooks")
      end
   end

   if path:match("^docs/code_style/c_language/") then
      changed.mark("c")
   end

   if path:match("^tools/ci/") then
      changed.mark("ci")
   end

   if path:match("^tools/lint/code/actions/") then
      changed.mark("actions")
   elseif path:match("^tools/lint/code/lua/") then
      changed.mark("lua")
   elseif path:match("^tools/lint/code/c/") then
      changed.mark("c")
   elseif path:match("^tools/lint/code/python/") then
      changed.mark("python")
   elseif path:match("^tools/lint/code/shell/bash/")
      or path:match("^tools/lint/code/shell/posix/")
   then
      changed.mark("shell")
   elseif path:match("^tools/lint/code/shell/powershell/") then
      changed.mark("powershell")
   elseif path:match("^tools/lint/code/shell/nushell/") then
      changed.mark("nushell")
   elseif path:match("^tools/lint/code/md/") then
      changed.mark("markdown")
   end

   if path:match("^tools/lint/spell/") then
      changed.mark("hooks")
      changed.mark("spelling")
      if paths.ends_with(path, ".lua") then
         changed.mark("lua")
      end
   end

   if paths.ends_with(path, ".c")
      or paths.ends_with(path, ".h")
      or paths.ends_with(path, ".i")
   then
      changed.mark("c")
      changed.mark("bazel")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".lua") then
      changed.mark("lua")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".py") or paths.ends_with(path, ".pyi") then
      changed.mark("python")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".sh") or paths.ends_with(path, ".bash") then
      changed.mark("shell")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".ps1")
      or paths.ends_with(path, ".psm1")
      or paths.ends_with(path, ".psd1")
   then
      changed.mark("powershell")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".nu") then
      changed.mark("nushell")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".json")
      or paths.ends_with(path, ".jsonc")
   then
      changed.mark("json")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".yml") or paths.ends_with(path, ".yaml") then
      changed.mark("yaml")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".toml") then
      changed.mark("toml")
      changed.mark("spelling")
   elseif paths.ends_with(path, ".md")
      or paths.ends_with(path, ".markdown")
   then
      changed.mark("markdown")
      changed.mark("spelling")
   end

   if path == "MODULE.bazel"
      or path == "WORKSPACE"
      or path == "WORKSPACE.bazel"
      or path:match("%.bazel$")
      or path:match("%.bzl$")
   then
      changed.mark("bazel")
   end
end

--- Write deterministic category outputs for GitHub Actions or local use.
local function emit_outputs()
   local output_path = os.getenv("GITHUB_OUTPUT")
   local handle = nil

   if output_path and output_path ~= "" then
      handle = io.open(output_path, "ab")
      if not handle then
         fail("cannot open GITHUB_OUTPUT for append.")
      end
   end

   for category, value in changed.each() do
      local line = category .. "=" .. tostring(value) .. "\n"
      if handle then
         handle:write(line)
      else
         io.write(line)
      end
   end

   if handle then
      handle:close()
   end
end

local base, head, force_all = parse_arguments()

if force_all or git_module.zero_revision(base) then
   changed.mark_all()
else
   if base == "" then
      base = git.parent(head) or ""
   end

   if base == "" then
      changed.mark_all()
   else
      local files = git.changed_files(base, head)
      if files == nil then
         fail("git diff failed for '" .. base .. ".." .. head .. "'.")
      end

      for _, path in ipairs(files) do
         classify(path)
      end
   end
end

emit_outputs()

-- EOF
