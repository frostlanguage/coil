-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Execute action policy scripts with adversarial inputs and no cloud access.
local platform = dofile("scripts/libs/platform.lua")
local download = ".github/actions/verified-download/action.yml"
local cache = ".github/actions/cache-plane/action.yml"
local count = 0

local function read(path)
   local handle = assert(io.open(path, "rb"))
   local source = handle:read("*a")
   assert(handle:close())
   return source
end

local function write(path, source)
   local handle = assert(io.open(path, "wb"))
   assert(handle:write(source))
   assert(handle:close())
end

local function script(path, target)
   local blocks = {}
   local current = nil
   for line in (read(path) .. "\n"):gmatch("(.-)\n") do
      if line == "      run: |" then
         current = {}
         blocks[#blocks + 1] = current
      elseif current and (line == "" or line:match("^        ")) then
         current[#current + 1] = line:gsub("^        ", "")
      else
         current = nil
      end
   end
   return table.concat(
      assert(blocks[target or 1], "Missing action script"),
      "\n"
   )
end

local function run(path, values, expected, output_pattern)
   local directory = platform.temporary_directory()
   local success, failure = xpcall(function()
      local bin = directory .. "/bin"
      platform.run({ "mkdir", "-p", "--", bin })
      -- Only the availability probe uses this stub; no cloud request is sent.
      write(bin .. "/aws", "#!/bin/sh\nexit 0\n")
      platform.run({ "chmod", "700", bin .. "/aws" })
      local output = directory .. "/output"
      write(output, "")
      local environment = {
         PATH = bin .. ":" .. assert(os.getenv("PATH")),
         RUNNER_TEMP = directory,
         RUNNER_OS = "Linux",
         RUNNER_ARCH = "X64",
         GITHUB_OUTPUT = output,
         GITHUB_STEP_SUMMARY = directory .. "/summary",
         TOOL_NAME = "fixture",
         TOOL_VERSION = "1.0",
         TOOL_FILENAME = "fixture.tar.gz",
         TOOL_SHA256 = string.rep("a", 64),
         TOOL_ORIGIN = "https://example.invalid",
         TOOL_DIRECTORY = "releases/v1",
         EVENT_NAME = "pull_request",
         REF_NAME = "main",
         DEFAULT_BRANCH = "main",
      }
      for key, value in pairs(values) do
         environment[key] = value
      end
      -- CWE-78: values are quoted argv, never substituted into the Bash body.
      local arguments = { "env", "-i" }
      for key, value in pairs(environment) do
         arguments[#arguments + 1] = key .. "=" .. value
      end
      for _, value in ipairs({
         "timeout",
         "10",
         "bash",
         "--noprofile",
         "--norc",
         "-euo",
         "pipefail",
         "-c",
         script(path),
      }) do
         arguments[#arguments + 1] = value
      end
      local actual = platform.command_succeeded_silent(arguments)
      assert(actual == expected, path .. ": unexpected policy result")
      local result = read(output)
      if not expected then
         assert(result == "", "Invalid input wrote GitHub outputs")
      end
      if output_pattern then
         assert(result:find(output_pattern), "Missing expected cache output")
      end
      count = count + 1
   end, debug.traceback)
   platform.remove_temporary_directory(directory)
   assert(success, failure)
end

run(download, {}, true, "fixture/1%.0/" .. string.rep("a", 64))
run(download, { TOOL_DIRECTORY = "releases/%40biomejs/biome%402.5.10" }, true)
for _, case in ipairs({
   { "TOOL_NAME", ".." },
   { "TOOL_VERSION", ".." },
   { "TOOL_FILENAME", "" },
   { "TOOL_FILENAME", "../outside" },
   { "TOOL_FILENAME", "file\ninjected=true" },
   { "TOOL_SHA256", "invalid" },
   { "TOOL_ORIGIN", "http://example.invalid" },
   { "TOOL_ORIGIN", "https://example.invalid?query" },
   { "TOOL_DIRECTORY", "../outside" },
   { "TOOL_DIRECTORY", "%2e%2e/outside" },
   { "COIL_CI_TOOL_CACHE_DIR", "/tmp/cache\ninjected=true" },
}) do
   run(download, { [case[1]] = case[2] }, false)
end
for _, path in ipairs({ download, cache }) do
   for _, event in ipairs({
      "pull_request",
      "merge_group",
      "push",
      "workflow_dispatch",
   }) do
      local trusted = event == "push" or event == "workflow_dispatch"
      run(path, {
         EVENT_NAME = event,
         COIL_CI_S3_CACHE_BUCKET = "fixture",
      }, true, "shared_cache_write=" .. tostring(trusted))
   end
   run(path, {
      COIL_CI_S3_CACHE_BUCKET = "fixture",
      COIL_CI_S3_CACHE_PREFIX = "safe\nunsafe",
   }, false)
   run(path, {
      COIL_CI_S3_CACHE_BUCKET = "fixture",
      COIL_CI_S3_CACHE_ENDPOINT = "http://cache.example.invalid",
   }, false)
   run(path, {
      COIL_CI_S3_CACHE_BUCKET = "fixture",
      COIL_CI_S3_CACHE_ENDPOINT = "http://localhost:80@cache.example.invalid",
   }, false)
   run(path, {
      COIL_CI_S3_CACHE_BUCKET = "fixture",
      EVENT_NAME = "push",
      REF_NAME = "feature",
   }, true, "shared_cache_write=false")
end
run(cache, {
   COIL_CI_BAZEL_REMOTE_CACHE = "grpc://cache.example.invalid:9092",
}, false)
run(cache, {
   COIL_CI_BAZEL_REMOTE_CACHE = "https://cache.invalid\nbuild --config=evil",
}, false)
run(cache, {
   COIL_CI_BAZEL_REMOTE_INSTANCE = "x\nbuild --action_env=TOKEN",
}, false)
local fetch = script(download, 2)
for _, required in ipairs({
   "--proto-redir '=https'",
   "--max-time 300",
   "mktemp",
   "sha256sum --check --strict",
}) do
   assert(fetch:find(required, 1, true), "Missing download defense")
end
print(string.format("CI security: %d adversarial policy cases passed.", count))

-- EOF
