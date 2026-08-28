#!/usr/bin/env lua

-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

local uv = require("luv")
local is_windows = os.getenv("OS") == "Windows_NT"
local path_separator = is_windows and "\\" or "/"

--- Join path components using the native directory separator.
-- @param ... string: Path components.
-- @return string: Joined path.
local function join_path(...)
   local parts = { ... }
   local path = tostring(parts[1] or "")

   for i = 2, #parts do
      local part = tostring(parts[i])
      local path_has_separator = path:sub(-1) == "/" or path:sub(-1) == "\\"
      local part_has_separator = part:sub(1, 1) == "/" or part:sub(1, 1) == "\\"

      if path_has_separator and part_has_separator then
         path = path .. part:sub(2)
      elseif path_has_separator or part_has_separator then
         path = path .. part
      else
         path = path .. path_separator .. part
      end
   end

   return path
end

--- Read an exact byte string from a file.
-- @param path string: Source path.
-- @return string: File contents.
local function read_file(path)
   local file, open_error = io.open(path, "rb")
   if not file then
      local message = "could not open file for reading: "
         .. path
         .. ": "
         .. tostring(open_error)
      error(message)
   end

   local contents = file:read("*a")
   file:close()
   return contents
end

--- Build a complete environment block with selected values overridden.
-- @param overrides table|nil: Environment variables to override.
-- @return table|nil: Environment block accepted by uv.spawn.
local function build_environment(overrides)
   if not overrides then
      return nil
   end

   local environment = uv.os_environ()
   for name, value in pairs(overrides) do
      environment[name] = tostring(value)
   end

   local entries = {}
   for name, value in pairs(environment) do
      entries[#entries + 1] = name .. "=" .. value
   end
   table.sort(entries)
   return entries
end

--- Execute a process directly through libuv without invoking a command shell.
-- @param arguments table: Program followed by its argument vector.
-- @param options table|nil: Process execution options, including cwd/env and
-- stream routing.
-- @return boolean, number, string, string|nil: Success, exit code, stdout,
-- and process error.
local function execute_process(arguments, options)
   options = options or {}

   if #arguments == 0 then
      return false, 1, "", "missing process executable"
   end

   local program = tostring(arguments[1])
   local process_arguments = {}
   for i = 2, #arguments do
      process_arguments[#process_arguments + 1] = tostring(arguments[i])
   end

   local stdin_contents
   if options.stdin_path then
      stdin_contents = read_file(options.stdin_path)
   end

   local stdin_pipe = stdin_contents and uv.new_pipe(false) or nil
   local stdout_pipe
   if options.capture_stdout or options.stdout_to_null then
      stdout_pipe = uv.new_pipe(false)
   end
   local stderr_pipe = options.stderr_to_null and uv.new_pipe(false) or nil
   local stdout_chunks = {}
   local process_error
   local exit_code = 1

   local stdio = {
      stdin_pipe or 0,
      stdout_pipe or 1,
      stderr_pipe or 2,
   }

   local process_handle
   local spawn_error
   process_handle, spawn_error = uv.spawn(program, {
      args = process_arguments,
      cwd = options.cwd,
      env = build_environment(options.env),
      stdio = stdio,
   }, function(code, _)
      exit_code = code
      process_handle:close()
   end)

   if not process_handle then
      if stdin_pipe then
         stdin_pipe:close()
      end
      if stdout_pipe then
         stdout_pipe:close()
      end
      if stderr_pipe then
         stderr_pipe:close()
      end
      uv.run()
      return false, 1, "", tostring(spawn_error)
   end

   if stdout_pipe then
      stdout_pipe:read_start(function(read_error, data)
         if read_error then
            process_error = process_error or tostring(read_error)
            stdout_pipe:close()
            return
         end

         if data then
            if options.capture_stdout then
               stdout_chunks[#stdout_chunks + 1] = data
            end
            return
         end

         stdout_pipe:read_stop()
         stdout_pipe:close()
      end)
   end

   if stderr_pipe then
      stderr_pipe:read_start(function(read_error, data)
         if read_error then
            process_error = process_error or tostring(read_error)
            stderr_pipe:close()
            return
         end

         if data then
            return
         end

         stderr_pipe:read_stop()
         stderr_pipe:close()
      end)
   end

   if stdin_pipe then
      stdin_pipe:write(stdin_contents)
      stdin_pipe:shutdown(function(shutdown_error)
         if shutdown_error then
            process_error = process_error or tostring(shutdown_error)
         end
         stdin_pipe:close()
      end)
   end

   uv.run()

   if process_error then
      return false, exit_code, table.concat(stdout_chunks), process_error
   end

   return exit_code == 0, exit_code, table.concat(stdout_chunks), nil
end

--- Execute an external program.
-- @param arguments table: Program followed by its arguments.
-- @param options table|nil: Process execution options.
-- @return boolean, number: Success flag and exit code.
local function run_command(arguments, options)
   local success, exit_code = execute_process(arguments, options)
   return success, exit_code
end

--- Capture standard output from an external program.
-- @param arguments table: Program followed by its arguments.
-- @param options table|nil: Process execution options.
-- @return string, boolean, number: Output, success flag, and exit code.
local function capture_command(arguments, options)
   local capture_options = {}
   for name, value in pairs(options or {}) do
      capture_options[name] = value
   end
   capture_options.capture_stdout = true
   capture_options.stdout_to_null = false

   local success, exit_code, output =
      execute_process(arguments, capture_options)
   return output, success, exit_code
end

--- Remove leading and trailing whitespace.
-- @param value string: Value to trim.
-- @return string: Trimmed value.
local function trim(value)
   return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Remove a directory tree without invoking rm, rmdir, or a shell.
-- @param path string: Directory tree to remove.
local function remove_tree(path)
   local stat = uv.fs_stat(path)
   if not stat then
      return
   end

   if stat.type ~= "directory" then
      local success, unlink_error = uv.fs_unlink(path)
      if not success then
         error(
            "could not remove file: " .. path .. ": " .. tostring(unlink_error)
         )
      end
      return
   end

   local scanner, scan_error = uv.fs_scandir(path)
   if not scanner then
      error(
         "could not scan directory: " .. path .. ": " .. tostring(scan_error)
      )
   end

   while true do
      local name = uv.fs_scandir_next(scanner)
      if not name then
         break
      end
      remove_tree(join_path(path, name))
   end

   local success, remove_error = uv.fs_rmdir(path)
   if not success then
      error(
         "could not remove directory: "
            .. path
            .. ": "
            .. tostring(remove_error)
      )
   end
end

--- Create a unique temporary directory using libuv.
-- @param suffix string: Human-readable suffix.
-- @return string: Temporary directory path.
local function create_temporary_directory(suffix)
   local temporary_root, root_error = uv.os_tmpdir()
   if not temporary_root then
      error(
         "could not resolve the temporary directory: " .. tostring(root_error)
      )
   end

   local template = join_path(temporary_root, suffix .. "-XXXXXX")
   local directory, create_error = uv.fs_mkdtemp(template)
   if not directory then
      error("could not create temporary directory: " .. tostring(create_error))
   end

   return directory
end

--- Write an exact byte string to a file.
-- @param path string: Destination path.
-- @param contents string: File contents.
local function write_file(path, contents)
   local file, open_error = io.open(path, "wb")
   if not file then
      local message = "could not open file for writing: "
         .. path
         .. ": "
         .. tostring(open_error)
      error(message)
   end

   local success, write_error = file:write(contents)
   file:close()

   if not success then
      error("could not write file: " .. path .. ": " .. tostring(write_error))
   end
end

--- Replace named fixture placeholders.
-- @param template string: Fixture template.
-- @param values table: Placeholder values.
-- @return string: Rendered fixture.
local function render_fixture(template, values)
   return (
      template:gsub("{{([A-Z_]+)}}", function(name)
         local value = values[name]
         if value == nil then
            error("missing fixture placeholder: " .. name)
         end

         return value
      end)
   )
end

--- Resolve the repository root from the current working directory.
-- @return string: Absolute repository root.
local function resolve_repository_root()
   local output, success = capture_command(
      { "git", "rev-parse", "--show-toplevel" },
      { stderr_to_null = true }
   )

   if not success then
      error("run this test from inside the Coil repository")
   end

   local repository_root = trim(output)
   if repository_root == "" then
      error("run this test from inside the Coil repository")
   end

   return repository_root
end

--- Capture a Git configuration value without treating a missing key as fatal.
-- @param repository_root string: Repository root.
-- @param key string: Git configuration key.
-- @return string: Configuration value or an empty string.
local function git_config(repository_root, key)
   local output, success = capture_command(
      { "git", "config", "--get", key },
      { cwd = repository_root, stderr_to_null = true }
   )

   if not success then
      return ""
   end

   return trim(output)
end

local function main()
   local repository_root = resolve_repository_root()
   local lua_bin = os.getenv("LUA") or "lua"
   local hook_path = join_path(repository_root, ".githooks", "commit-msg")
   local test_directory = create_temporary_directory("coil-hook-tests")
   local user_name = git_config(repository_root, "user.name")
   local user_email = git_config(repository_root, "user.email")
   local remote = git_config(repository_root, "remote.pushDefault")

   if user_name == "" then
      user_name = "Coil Test User"
   end
   if user_email == "" then
      user_email = "coil-tests@example.org"
   end

   if remote == "" then
      local branch_output, branch_success = capture_command(
         { "git", "branch", "--show-current" },
         { cwd = repository_root, stderr_to_null = true }
      )
      local branch = branch_success and trim(branch_output) or ""

      if branch ~= "" then
         remote = git_config(repository_root, "branch." .. branch .. ".remote")
      end
   end

   if remote == "" or remote == "." then
      remote = "origin"
   end

   local remote_output, remote_success = capture_command(
      { "git", "ls-remote", remote, "refs/heads/main" },
      { cwd = repository_root, stderr_to_null = true }
   )
   local remote_main_sha = ""
   if remote_success then
      remote_main_sha = remote_output:match("^([0-9a-fA-F]+)") or ""
   end

   local missing_url = "https://raw.githubusercontent.com/"
      .. "frostlanguage/coil/main/__lychee_missing_test_9f371e__.md"

   local fixture_values = {
      NAME = user_name,
      EMAIL = user_email,
      REMOTE_MAIN_SHA = remote_main_sha,
      LONG_DETAILS = string.rep("x", 72),
      MISSING_URL = missing_url,
   }

   local fixtures = {
      ["00-good.txt"] = [[ci(policy): validate commit policy

Motivation: coil needs deterministic commit metadata across
contributors.

Details: validate repository-local commit structure and provenance.

Impact: this change affects contribution policy and metadata
validation.

Theory-reference: Conventional Commits.
URL: https://www.conventionalcommits.org/en/v1.0.0/
Reviewed-by: Example Reviewer <reviewer@example.org>
Assisted-by: repository automation
Refs: branch main

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["01-good-doi.txt"] = [[docs(policy): document publication references

Motivation: coil needs references that identify published literature.

Details: allow a theory reference to use a digital object identifier.

Impact: this change affects commit metadata validation.

Theory-reference: Example publication.
DOI: 10.1145/1234567.1234568

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["02-good-utf8.txt"] = [[ci(policy): validate UTF-8 character counting

Motivation: coil needs character-based commit message limits.

Details: add UTF-8 character counting for messages ✓ ✓ ✓ ✓ ✓ ✓ ✓ ✓.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["03-good-breaking.txt"] = [[
feat(api)!: replace the legacy string interface

Motivation: coil needs one stable string interface for future releases.

Details: replace the legacy entry point with the new public interface.

Impact: callers must migrate to the replacement interface.

BREAKING CHANGE: callers must use the replacement string interface.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["04-good-breaking-hyphen.txt"] = [[
feat(api): replace a legacy entry point

Motivation: coil needs one stable entry point for future releases.

Details: replace the legacy entry point with the current interface.

Impact: callers must migrate to the current interface.

BREAKING-CHANGE: callers must use the current entry point.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["05-good-remote-commit.txt"] = [[
chore(policy): verify remote commit references

Motivation: coil needs repository citations that resolve remotely.

Details: verify a cited commit through the configured remote.

Impact: this change affects commit metadata validation.

Refs: commit {{REMOTE_MAIN_SHA}}

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["06-good-remote-ref.txt"] = [[chore(policy): verify remote ref references

Motivation: coil needs repository citations that resolve remotely.

Details: verify a cited Git reference through the configured remote.

Impact: this change affects commit metadata validation.

Refs: ref refs/heads/main
Follows-up: branch main

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["10-bad-type.txt"] = [[security(policy): reject unsupported commit types

Motivation: coil needs a stable conventional commit type set.

Details: reject commit types outside the configured allowlist.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["11-extra-subject-blank.txt"] = [[
ci(policy): reject extra subject separators


Motivation: coil needs exactly one blank line after the subject.

Details: reject multiple blank separator lines before the body.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["12-number-uppercase.txt"] = [[
ci(policy): validate the first alphabetic character

Motivation: 2026 Coil needs deterministic lowercase validation.

Details: reject uppercase text after leading digits or punctuation.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["13-no-scope.txt"] = [[ci: reject a missing scope

Motivation: coil needs a scope on every conventional commit.

Details: reject subjects that omit the mandatory scope.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["14-uppercase-subject.txt"] = [[ci(policy): Reject uppercase descriptions

Motivation: coil needs deterministic lowercase validation.

Details: reject uppercase subject descriptions.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["15-long-line.txt"] = [[ci(policy): validate commit line limits

Motivation: coil needs deterministic formatting for commit messages.

Details: {{LONG_DETAILS}}

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["16-no-motivation.txt"] = [[ci(policy): validate required sections

Details: add repository-local commit validation.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["17-no-details.txt"] = [[ci(policy): validate required sections

Motivation: coil needs deterministic commit metadata.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["18-no-impact.txt"] = [[ci(policy): validate required sections

Motivation: coil needs deterministic commit metadata.

Details: add repository-local commit validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["19-bad-theory-reference.txt"] = [[
docs(policy): validate technical reference trailers

Motivation: coil needs deterministic reference metadata.

Details: reject a theory reference without an identifier.

Impact: this change affects commit metadata validation.

Theory-reference: Conventional Commits.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["20-orphan-url.txt"] = [[
docs(policy): validate technical reference trailers

Motivation: coil needs deterministic reference metadata.

Details: reject an identifier without its theory reference.

Impact: this change affects commit metadata validation.

URL: https://www.conventionalcommits.org/en/v1.0.0/

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["21-bad-doi.txt"] = [[docs(policy): validate publication identifiers

Motivation: coil needs deterministic publication metadata.

Details: reject malformed publication identifiers.

Impact: this change affects commit metadata validation.

Theory-reference: Example publication.
DOI: invalid-doi-value

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["22-bad-dco.txt"] = [[ci(policy): validate developer certificate signoff

Motivation: coil needs authorship metadata for contributions.

Details: reject a sign-off that differs from the configured author.

Impact: this change affects contribution policy.

Signed-off-by: Invalid Contributor <invalid@example.org>
]],
      ["23-blank-inside-footers.txt"] = [[ci(policy): reject split footer blocks

Motivation: coil needs trailers that remain one contiguous Git footer block.

Details: reject blank lines between structured footer entries.

Impact: this change affects commit metadata validation.

Reviewed-by: Example Reviewer <reviewer@example.org>

Assisted-by: repository automation

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["24-unknown-footer.txt"] = [[ci(policy): reject unsupported footer tokens

Motivation: coil needs a defined set of commit metadata trailers.

Details: reject metadata tokens that are outside the policy.

Impact: this change affects commit metadata validation.

Unknown-by: Example Person <person@example.org>

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["25-bad-reviewed-by.txt"] = [[ci(policy): validate reviewer attribution

Motivation: coil needs structured reviewer provenance.

Details: reject reviewer attribution without an email address.

Impact: this change affects commit metadata validation.

Reviewed-by: Example Reviewer

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["26-two-breaking.txt"] = [[feat(api)!: reject duplicate breaking metadata

Motivation: coil needs one canonical breaking-change footer.

Details: reject duplicate breaking-change footer declarations.

Impact: this change affects commit metadata validation.

BREAKING CHANGE: callers must migrate to the replacement interface.
BREAKING-CHANGE: callers must also migrate to the replacement interface.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["27-breaking-uppercase.txt"] = [[
feat(api): validate breaking-change descriptions

Motivation: coil needs deterministic lowercase footer descriptions.

Details: reject uppercase breaking-change descriptions.

Impact: this change affects commit metadata validation.

BREAKING CHANGE: Callers must migrate to the replacement interface.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["28-bad-ref-syntax.txt"] = [[
chore(policy): validate repository reference syntax

Motivation: coil needs machine-readable repository references.

Details: reject repository references that omit an object kind.

Impact: this change affects commit metadata validation.

Refs: something somewhere

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["29-missing-branch.txt"] = [[
chore(policy): reject missing remote branches

Motivation: coil needs repository citations that resolve remotely.

Details: reject a cited branch that the configured remote does not advertise.

Impact: this change affects commit metadata validation.

Refs: branch __coil_missing_branch_9f371e__

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["30-missing-tag.txt"] = [[chore(policy): reject missing remote tags

Motivation: coil needs repository citations that resolve remotely.

Details: reject a cited tag that the configured remote does not advertise.

Impact: this change affects commit metadata validation.

Refs: tag __coil_missing_tag_9f371e__

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["31-missing-commit.txt"] = [[chore(policy): reject missing remote commits

Motivation: coil needs repository citations that resolve remotely.

Details: reject a cited commit that does not exist on the remote.

Impact: this change affects commit metadata validation.

Refs: commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["32-missing-issue.txt"] = [[chore(policy): reject missing remote issues

Motivation: coil needs repository citations that resolve remotely.

Details: reject a cited issue that does not exist on the remote.

Impact: this change affects commit metadata validation.

Refs: issue #99999999

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["33-missing-pull.txt"] = [[
chore(policy): reject missing remote pull requests

Motivation: coil needs repository citations that resolve remotely.

Details: reject a cited pull request that does not exist on the remote.

Impact: this change affects commit metadata validation.

Refs: pull #99999999

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["34-fixes-commit.txt"] = [[fix(policy): restrict issue-closing footers

Motivation: coil needs issue-closing metadata with unambiguous semantics.

Details: reject a Fixes footer that cites a non-issue object.

Impact: this change affects commit metadata validation.

Fixes: commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["35-no-signoff-separator.txt"] = [[
ci(policy): reject a missing DCO separator

Motivation: coil needs a visually isolated final DCO trailer.

Details: reject a sign-off without its required blank separator.

Impact: this change affects commit metadata validation.
Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["36-extra-signoff-separator.txt"] = [[
ci(policy): reject extra DCO separator lines

Motivation: coil needs exactly one blank line before the DCO trailer.

Details: reject multiple blank lines before the final sign-off.

Impact: this change affects commit metadata validation.


Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["37-duplicate-signoff.txt"] = [[ci(policy): reject duplicate DCO trailers

Motivation: coil needs exactly one developer certificate sign-off.

Details: reject messages that contain more than one DCO trailer.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["38-no-details-separator.txt"] = [[ci(policy): require section separators

Motivation: coil needs visually separated commit sections.
Details: reject a missing blank line before the details section.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["39-no-impact-separator.txt"] = [[ci(policy): require section separators

Motivation: coil needs visually separated commit sections.

Details: reject a missing blank line before the impact section.
Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["40-cspell.txt"] = [[docs(spelling): validate unknown words

Motivation: coil needs spelling validation for commit messages.

Details: add qxylophoniczz validation to this commit message.

Impact: this change affects contribution policy.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["41-codespell.txt"] = [[docs(spelling): validate common misspellings

Motivation: coil needs spelling validation for commit messages.

Details: add teh validation path for commit messages.

Impact: this change affects contribution policy.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["42-typos.txt"] = [[docs(spelling): validate typographical errors

Motivation: coil needs typo validation for commit messages.

Details: validate a retrun value in this test message.

Impact: this change affects contribution policy.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["43-vale.txt"] = [[docs(prose): validate passive voice rules

Motivation: coil needs deterministic prose validation for commits.

Details: the repository hook was implemented by the test runner.

Impact: this change affects contribution policy.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["44-lychee.txt"] = [[docs(links): validate commit reference links

Motivation: coil needs link validation for commit references.

Details: add an unreachable documentation reference for this test.

Impact: this change affects contribution policy.

Theory-reference: Missing test resource.
URL: {{MISSING_URL}}

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["45-extra-details-separator.txt"] = [[
ci(policy): reject extra section separators

Motivation: coil needs exactly one blank line between sections.


Details: reject extra blank lines before the details section.

Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
      ["46-extra-impact-separator.txt"] = [[
ci(policy): reject extra section separators

Motivation: coil needs exactly one blank line between sections.

Details: reject extra blank lines before the impact section.


Impact: this change affects commit metadata validation.

Signed-off-by: {{NAME}} <{{EMAIL}}>
]],
   }

   for file_name, contents in pairs(fixtures) do
      local path = join_path(test_directory, file_name)
      write_file(path, render_fixture(contents, fixture_values))
   end

   local expected = 0
   local unexpected = 0
   local skipped = 0

   local function header(title)
      print("")
      print("================================================================")
      print(title)
      print("================================================================")
   end

   local function run_hook(file_name)
      local file_path = join_path(test_directory, file_name)
      return run_command(
         { lua_bin, hook_path, file_path },
         { cwd = repository_root }
      )
   end

   local function expect_pass(name, file_name)
      header("EXPECT PASS: " .. name)

      if run_hook(file_name) then
         print("RESULT: PASS as expected")
         expected = expected + 1
         return
      end

      print("RESULT: UNEXPECTED FAILURE")
      unexpected = unexpected + 1
   end

   local function expect_fail(name, file_name)
      header("EXPECT FAIL: " .. name)

      if run_hook(file_name) then
         print("RESULT: UNEXPECTED PASS")
         unexpected = unexpected + 1
         return
      end

      print("RESULT: FAIL as expected")
      expected = expected + 1
   end

   header("COMMIT POLICY TESTS")
   expect_pass("complete valid footer block", "00-good.txt")
   expect_pass("valid DOI reference", "01-good-doi.txt")
   expect_pass("UTF-8 character count", "02-good-utf8.txt")
   expect_pass("BREAKING CHANGE footer", "03-good-breaking.txt")
   expect_pass("BREAKING-CHANGE synonym", "04-good-breaking-hyphen.txt")

   if remote_main_sha ~= "" then
      expect_pass("existing remote commit", "05-good-remote-commit.txt")
   else
      print("SKIP: remote main commit could not be resolved")
      skipped = skipped + 1
   end

   expect_pass("existing remote ref and branch", "06-good-remote-ref.txt")
   expect_fail("unsupported commit type", "10-bad-type.txt")
   expect_fail("extra subject separator", "11-extra-subject-blank.txt")
   expect_fail(
      "first alphabetic character uppercase",
      "12-number-uppercase.txt"
   )
   expect_fail("missing scope", "13-no-scope.txt")
   expect_fail("uppercase subject", "14-uppercase-subject.txt")
   expect_fail("71-character limit", "15-long-line.txt")
   expect_fail("missing Motivation", "16-no-motivation.txt")
   expect_fail("missing Details", "17-no-details.txt")
   expect_fail("missing Impact", "18-no-impact.txt")
   expect_fail(
      "Theory-reference missing identifier",
      "19-bad-theory-reference.txt"
   )
   expect_fail("orphan URL", "20-orphan-url.txt")
   expect_fail("malformed DOI", "21-bad-doi.txt")
   expect_fail("DCO mismatch", "22-bad-dco.txt")
   expect_fail("blank line inside footer block", "23-blank-inside-footers.txt")
   expect_fail("unsupported footer token", "24-unknown-footer.txt")
   expect_fail("malformed Reviewed-by", "25-bad-reviewed-by.txt")
   expect_fail("duplicate BREAKING CHANGE footer", "26-two-breaking.txt")
   expect_fail(
      "uppercase BREAKING CHANGE description",
      "27-breaking-uppercase.txt"
   )
   expect_fail("invalid repository reference syntax", "28-bad-ref-syntax.txt")
   expect_fail("missing remote branch", "29-missing-branch.txt")
   expect_fail("missing remote tag", "30-missing-tag.txt")
   expect_fail("missing remote commit", "31-missing-commit.txt")
   expect_fail("missing remote issue", "32-missing-issue.txt")
   expect_fail("missing remote pull request", "33-missing-pull.txt")
   expect_fail("Fixes cannot cite a commit", "34-fixes-commit.txt")
   expect_fail(
      "missing blank line before Signed-off-by",
      "35-no-signoff-separator.txt"
   )
   expect_fail(
      "extra blank lines before Signed-off-by",
      "36-extra-signoff-separator.txt"
   )
   expect_fail("duplicate Signed-off-by trailer", "37-duplicate-signoff.txt")
   expect_fail(
      "missing blank line before Details",
      "38-no-details-separator.txt"
   )
   expect_fail("missing blank line before Impact", "39-no-impact-separator.txt")
   expect_fail("CSpell unknown word", "40-cspell.txt")
   expect_fail("codespell common misspelling", "41-codespell.txt")
   expect_fail("typos typographical error", "42-typos.txt")
   expect_fail("Vale passive voice", "43-vale.txt")
   expect_fail("Lychee unreachable URL", "44-lychee.txt")
   expect_fail(
      "extra blank lines before Details",
      "45-extra-details-separator.txt"
   )
   expect_fail(
      "extra blank lines before Impact",
      "46-extra-impact-separator.txt"
   )

   print("")
   print("================================================================")
   local summary = string.format(
      "SUMMARY: %d expected, %d unexpected, %d skipped",
      expected,
      unexpected,
      skipped
   )
   print(summary)
   print("================================================================")

   remove_tree(test_directory)

   if unexpected ~= 0 or skipped ~= 0 then
      return 1
   end

   return 0
end

local success, result = xpcall(main, debug.traceback)
if not success then
   io.stderr:write("error: ", tostring(result), "\n")
   os.exit(1)
end

os.exit(result)

-- EOF
