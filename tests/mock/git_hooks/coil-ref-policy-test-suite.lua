#!/usr/bin/env lua

-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

local uv = require("luv")
local path_separator = package.config:sub(1, 1)

local DEFAULT_DIRECTORY_MODE = tonumber("755", 8)
local PRIVATE_DIRECTORY_MODE = tonumber("700", 8)

--- Join path components using the native directory separator.
-- @param ... string: Path components.
-- @return string: Joined path.
local function join_path(...)
   local parts = {...}
   local path = tostring(parts[1] or "")

   for i = 2, #parts do
      local part = tostring(parts[i])
      local path_has_separator = path:sub(-1) == "/" or path:sub(-1) == "\\"
      local part_has_separator = part:sub(1, 1) == "/" or part:sub(1, 1) == "\\"

      if path_has_separator and part_has_separator then
         path = path..part:sub(2)
      elseif path_has_separator or part_has_separator then
         path = path..part
      else
         path = path..path_separator..part
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
      local message =
         "could not open file for reading: "..path..": "..tostring(open_error)
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
      entries[#entries + 1] = name.."="..value
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

--- Execute an external program and fail immediately if it exits unsuccessfully.
-- @param arguments table: Program followed by its arguments.
-- @param options table|nil: Process execution options.
local function require_command(arguments, options)
   local success, exit_code, _, process_error = execute_process(
      arguments,
      options
   )
   if success then
      return
   end

   local detail = process_error and ": "..process_error or ""
   local message =
      "command failed with exit code "..tostring(exit_code)..": "..
      table.concat(arguments, " ")..detail
   error(message)
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

   local success, exit_code, output = execute_process(
      arguments,
      capture_options
   )
   return output, success, exit_code
end

--- Capture standard output and fail if the command exits unsuccessfully.
-- @param arguments table: Program followed by its arguments.
-- @param options table|nil: Process execution options.
-- @return string: Captured output.
local function require_capture(arguments, options)
   local capture_options = {}
   for name, value in pairs(options or {}) do
      capture_options[name] = value
   end
   capture_options.capture_stdout = true
   capture_options.stdout_to_null = false

   local success, exit_code, output, process_error = execute_process(
      arguments,
      capture_options
   )
   if not success then
      local detail = process_error and ": "..process_error or ""
      local message =
      "command failed with exit code "..tostring(exit_code)..": "..
      table.concat(arguments, " ")..detail
   error(message)
   end

   return output
end

--- Remove leading and trailing whitespace.
-- @param value string: Value to trim.
-- @return string: Trimmed value.
local function trim(value)
   return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Create one directory without invoking mkdir or a command shell.
-- @param path string: Directory path whose parent already exists.
-- @param mode number|nil: POSIX mode; ignored as appropriate by the platform.
local function make_directory(path, mode)
   local success, create_error = uv.fs_mkdir(
      path,
      mode or DEFAULT_DIRECTORY_MODE
   )

   if not success then
      error("could not create directory: "..path..": "..tostring(create_error))
   end
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
         error("could not remove file: "..path..": "..tostring(unlink_error))
      end
      return
   end

   local scanner, scan_error = uv.fs_scandir(path)
   if not scanner then
      error("could not scan directory: "..path..": "..tostring(scan_error))
   end

   while true do
      local name = uv.fs_scandir_next(scanner)
      if not name then break end
      remove_tree(join_path(path, name))
   end

   local success, remove_error = uv.fs_rmdir(path)
   if not success then
      error("could not remove directory: "..path..": "..tostring(remove_error))
   end
end

--- Create a unique temporary directory using libuv.
-- @param suffix string: Human-readable suffix.
-- @return string: Temporary directory path.
local function create_temporary_directory(suffix)
   local temporary_root, root_error = uv.os_tmpdir()
   if not temporary_root then
      error("could not resolve the temporary directory: "..tostring(root_error))
   end

   local template = join_path(temporary_root, suffix.."-XXXXXX")
   local directory, create_error = uv.fs_mkdtemp(template)
   if not directory then
      error("could not create temporary directory: "..tostring(create_error))
   end

   return directory
end

--- Copy one file without relying on cp or copy.
-- @param source_path string: Source file path.
-- @param destination_path string: Destination file path.
local function copy_file(source_path, destination_path)
   local source, source_error = io.open(source_path, "rb")
   if not source then
      local message =
         "could not open source file: "..source_path..": "..
         tostring(source_error)
      error(message)
   end

   local contents = source:read("*a")
   source:close()

   local destination, destination_error = io.open(destination_path, "wb")
   if not destination then
      local message =
         "could not open destination file: "..destination_path..": "..
         tostring(destination_error)
      error(message)
   end

   local success, write_error = destination:write(contents)
   destination:close()

   if not success then
      local message =
         "could not copy file to: "..destination_path..": "..
         tostring(write_error)
      error(message)
   end
end

--- Write an exact byte string to a file.
-- @param path string: Destination path.
-- @param contents string: File contents.
local function write_file(path, contents)
   local file, open_error = io.open(path, "wb")
   if not file then
      local message =
         "could not open file for writing: "..path..": "..tostring(open_error)
      error(message)
   end

   local success, write_error = file:write(contents)
   file:close()

   if not success then
      error("could not write file: "..path..": "..tostring(write_error))
   end
end

--- Resolve the repository root from the current working directory.
-- @return string: Absolute repository root.
local function resolve_repository_root()
   local output, success = capture_command(
      {"git", "rev-parse", "--show-toplevel"},
      {stderr_to_null = true}
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

--- Find the first secret-key identifier in GnuPG colon output.
-- @param output string: Output from gpg --with-colons --list-secret-keys.
-- @return string|nil: Key identifier.
local function find_secret_key(output)
   for line in output:gmatch("[^\r\n]+") do
      local key = line:match("^sec:[^:]*:[^:]*:[^:]*:([^:]+):")
      if key then
         return key
      end
   end

   return nil
end

--- Run the ref-policy test suite in an isolated repository.
-- @param repository_root string: Coil repository root.
-- @param temporary_root string: Temporary test root.
-- @return number: Process exit code.
local function run_test_suite(repository_root, temporary_root)
   local repository = join_path(temporary_root, "repo")
   local remote = join_path(temporary_root, "remote.git")
   local gnupg_home = join_path(temporary_root, "gnupg")
   local lua_bin = os.getenv("LUA") or "lua"
   local environment = {
      GNUPGHOME = gnupg_home,
   }

   make_directory(gnupg_home, PRIVATE_DIRECTORY_MODE)

   require_command(
      {
         "gpg",
         "--batch",
         "--passphrase",
         "",
         "--quick-gen-key",
         "Coil Ref Test <coil-ref-test@example.org>",
         "ed25519",
         "sign",
         "1d",
      },
      {env = environment, stdout_to_null = true, stderr_to_null = true}
   )

   local secret_keys = require_capture(
      {"gpg", "--batch", "--with-colons", "--list-secret-keys"},
      {env = environment, stderr_to_null = true}
   )
   local signing_key = find_secret_key(secret_keys)
   if not signing_key then
      error("could not resolve the generated GnuPG signing key")
   end

   require_command({"git", "init", "--bare", remote}, {stdout_to_null = true})
   require_command(
      {"git", "init", "-b", "main", repository},
      {stdout_to_null = true}
   )

   make_directory(join_path(repository, ".githooks"))
   make_directory(join_path(repository, "tools"))
   make_directory(join_path(repository, "tools", "security"))
   make_directory(join_path(repository, "tools", "security", "git"))

   copy_file(
      join_path(repository_root, ".githooks", "pre-commit"),
      join_path(repository, ".githooks", "pre-commit")
   )
   copy_file(
      join_path(repository_root, ".githooks", "pre-push"),
      join_path(repository, ".githooks", "pre-push")
   )
   copy_file(
      join_path(repository_root, ".githooks", "commit-msg"),
      join_path(repository, ".githooks", "commit-msg")
   )
   copy_file(
      join_path(repository_root, "tools", "security", "git", "gitleaks.toml"),
      join_path(repository, "tools", "security", "git", "gitleaks.toml")
   )

   local command_options = {
      cwd = repository,
      env = environment,
   }
   local silent_options = {
      cwd = repository,
      env = environment,
      stdout_to_null = true,
   }

   local function git(arguments, silent)
      local command = {"git"}
      for _, argument in ipairs(arguments) do
         command[#command + 1] = argument
      end

      require_command(command, silent and silent_options or command_options)
   end

   local function capture_git(arguments)
      local command = {"git"}
      for _, argument in ipairs(arguments) do
         command[#command + 1] = argument
      end

      return trim(require_capture(command, command_options))
   end

   git({"config", "user.name", "Coil Ref Test"})
   git({"config", "user.email", "coil-ref-test@example.org"})
   git({"config", "commit.gpgSign", "true"})
   git({"config", "gpg.format", "openpgp"})
   git({"config", "user.signingkey", signing_key})
   git({"remote", "add", "origin", remote})

   write_file(join_path(repository, "README.md"), "initial\n")
   git({"add", "README.md"})
   git(
      {
         "commit",
         "--no-verify",
         "-S",
         "-m",
         "chore(repo): create reference test repository",
         "-m",
         "Motivation: coil needs a repository for reference policy tests.",
         "-m",
         "Details: create deterministic branch and tag fixtures.",
         "-m",
         "Impact: this change affects only the local policy test harness.",
         "-m",
         "Signed-off-by: Coil Ref Test <coil-ref-test@example.org>",
      },
      true
   )

   git({"branch", "develop"})
   git({"push", "--no-verify", "origin", "main", "develop"}, true)

   local signed_commit = capture_git({"rev-parse", "HEAD"})
   local remote_main = capture_git({"rev-parse", "HEAD"})
   local zero = string.rep("0", 40)
   local pre_push_input = join_path(temporary_root, "pre-push-input.txt")
   local passed = 0
   local failed = 0

   local function expect_pass(name, action)
      print("")
      print("EXPECT PASS: "..name)

      if action() then
         print("RESULT: PASS as expected")
         passed = passed + 1
         return
      end

      print("RESULT: UNEXPECTED FAILURE")
      failed = failed + 1
   end

   local function expect_fail(name, action)
      print("")
      print("EXPECT FAIL: "..name)

      if action() then
         print("RESULT: UNEXPECTED PASS")
         failed = failed + 1
         return
      end

      print("RESULT: FAIL as expected")
      passed = passed + 1
   end

   local function run_pre_commit()
      return run_command(
         {lua_bin, join_path(repository, ".githooks", "pre-commit")},
         command_options
      )
   end

   local function run_pre_push(input)
      write_file(pre_push_input, input.."\n")
      return run_command(
         {
            lua_bin,
            join_path(repository, ".githooks", "pre-push"),
            "origin",
            remote,
         },
         {
            cwd = repository,
            env = environment,
            stdin_path = pre_push_input,
         }
      )
   end

   local function switch_branch(name)
      git({"switch", name}, true)
   end

   local function create_branch(base, name)
      switch_branch(base)
      git({"switch", "-c", name}, true)
   end

   local function expect_pre_push_pass(name, input)
      expect_pass(name, function()
         return run_pre_push(input)
      end)
   end

   local function update_line(local_ref, local_sha, remote_ref, remote_sha)
      return local_ref.." "..local_sha.." "..remote_ref.." "..remote_sha
   end

   local function expect_pre_push_fail(name, input)
      expect_fail(name, function()
         return run_pre_push(input)
      end)
   end

   expect_pass("main branch", run_pre_commit)

   switch_branch("develop")
   expect_pass("develop branch", run_pre_commit)

   create_branch("develop", "feature/add-bounded-parsing")
   expect_pass("Gitflow feature branch", run_pre_commit)

   create_branch("develop", "feature/reject-invalid-sequences")
   expect_pass("second Gitflow feature branch", run_pre_commit)

   create_branch("develop", "release/1.2.0")
   expect_pass("Gitflow release branch", run_pre_commit)

   create_branch("main", "hotfix/1.2.1")
   expect_pass("Gitflow hotfix branch", run_pre_commit)

   create_branch("main", "support/1.2.3")
   expect_pass("Gitflow support branch", run_pre_commit)

   create_branch("develop", "feat/parser/add-bounded-parsing")
   expect_fail("old Conventional-derived branch name", run_pre_commit)

   create_branch("develop", "feature/Add-bounded-parsing")
   expect_fail("uppercase feature suffix", run_pre_commit)

   create_branch("develop", "feature/add_bounded_parsing")
   expect_fail("non-kebab feature suffix", run_pre_commit)

   create_branch("develop", "feature/add--bounded-parsing")
   expect_fail("double hyphen feature suffix", run_pre_commit)

   create_branch("develop", "feature/parser/add-bounded-parsing")
   expect_fail("nested feature branch suffix", run_pre_commit)

   create_branch("develop", "release/v1.2.0")
   expect_fail("v-prefixed release branch", run_pre_commit)

   create_branch("develop", "release/01.2.0")
   expect_fail("release branch with leading zero", run_pre_commit)

   create_branch("main", "hotfix/1.2")
   expect_fail("incomplete hotfix version", run_pre_commit)

   create_branch("main", "hotfix/1.2.1-rc.1")
   expect_fail("pre-release suffix on hotfix branch", run_pre_commit)

   create_branch("main", "support/1.2")
   expect_fail("incomplete support version", run_pre_commit)

   expect_pre_push_pass(
      "pre-push valid feature branch",
      update_line(
         "refs/heads/main",
         signed_commit,
         "refs/heads/feature/add-bounded-parsing",
         remote_main
      )
   )
   expect_pre_push_pass(
      "pre-push valid release branch",
      update_line(
         "refs/heads/main",
         signed_commit,
         "refs/heads/release/1.2.0",
         remote_main
      )
   )
   expect_pre_push_fail(
      "pre-push invalid old-style branch",
      update_line(
         "refs/heads/main",
         signed_commit,
         "refs/heads/feat/parser/add-bounded-parsing",
         remote_main
      )
   )

   expect_pre_push_pass(
      "SemVer 1.2.3 tag",
      "refs/tags/1.2.3 "..signed_commit.." refs/tags/1.2.3 "..zero
   )
   expect_pre_push_pass(
      "SemVer pre-release and build tag",
      update_line(
         "refs/tags/1.2.3-rc.1+build.7",
         signed_commit,
         "refs/tags/1.2.3-rc.1+build.7",
         zero
      )
   )
   expect_pre_push_pass(
      "SemVer zero major tag",
      "refs/tags/0.1.0 "..signed_commit.." refs/tags/0.1.0 "..zero
   )
   expect_pre_push_fail(
      "v-prefixed tag",
      "refs/tags/v1.2.3 "..signed_commit.." refs/tags/v1.2.3 "..zero
   )
   expect_pre_push_fail(
      "leading zero in MAJOR",
      "refs/tags/01.2.3 "..signed_commit.." refs/tags/01.2.3 "..zero
   )
   expect_pre_push_fail(
      "leading zero in MINOR",
      "refs/tags/1.02.3 "..signed_commit.." refs/tags/1.02.3 "..zero
   )
   expect_pre_push_fail(
      "leading zero in PATCH",
      "refs/tags/1.2.03 "..signed_commit.." refs/tags/1.2.03 "..zero
   )
   expect_pre_push_fail(
      "numeric pre-release leading zero",
      "refs/tags/1.2.3-rc.01 "..signed_commit.." refs/tags/1.2.3-rc.01 "..zero
   )
   expect_pre_push_fail(
      "empty pre-release identifier",
      update_line(
         "refs/tags/1.2.3-alpha..1",
         signed_commit,
         "refs/tags/1.2.3-alpha..1",
         zero
      )
   )
   expect_pre_push_fail(
      "invalid pre-release character",
      update_line(
         "refs/tags/1.2.3-alpha_1",
         signed_commit,
         "refs/tags/1.2.3-alpha_1",
         zero
      )
   )

   local other_object_path = join_path(temporary_root, "other-object.txt")
   write_file(other_object_path, "other\n")
   local other_object = capture_git({"hash-object", "-w", other_object_path})

   expect_pre_push_fail(
      "published SemVer tag update",
      "refs/tags/1.2.3 "..signed_commit.." refs/tags/1.2.3 "..other_object
   )
   expect_pre_push_fail(
      "published SemVer tag deletion",
      "refs/tags/1.2.3 "..zero.." refs/tags/1.2.3 "..signed_commit
   )

   print("")
   print(string.format("SUMMARY: %d expected, %d unexpected", passed, failed))

   if failed ~= 0 then
      return 1
   end

   return 0
end

local function main()
   local repository_root = resolve_repository_root()
   local temporary_root = create_temporary_directory("coil-ref-policy-tests")

   local success, result = xpcall(function()
      return run_test_suite(repository_root, temporary_root)
   end, debug.traceback)

   remove_tree(temporary_root)

   if not success then
      error(result, 0)
   end

   return result
end

local success, result = xpcall(main, debug.traceback)
if not success then
   io.stderr:write("error: ", tostring(result), "\n")
   os.exit(1)
end

os.exit(result)

-- EOF
