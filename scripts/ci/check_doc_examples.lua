-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Check references and the explicitly named complete C example files.
-- Deliberately invalid failure fragments are never compiled or executed.
local platform = dofile("scripts/libs/platform.lua")
local documents = {
   "c-code-standard.md",
   "c-module-architecture.md",
   "c-common-pitfalls.md",
}
local formatter = assert(
   platform.resolve_tool("COIL_CLANG_FORMAT", "clang-format"),
   "clang-format is required"
)
local tidy = assert(
   platform.resolve_tool("COIL_CLANG_TIDY", "clang-tidy"),
   "clang-tidy is required"
)

local function read(path)
   local handle = assert(io.open(path, "rb"))
   local source = handle:read("*a")
   assert(handle:close())
   return source
end

local function write(path, content)
   local handle = assert(io.open(path, "wb"))
   assert(handle:write(content))
   assert(handle:close())
end

local function references(source)
   local definitions = {}
   for key, url in source:gmatch("%[([^%]]+)%]:%s+(https://%S+)") do
      definitions[key] = url
   end
   local count = 0
   for section in source:gmatch("### CPIT%-%d+:([^#]+)") do
      local context = assert(
         section:match("%*%*External references:%*%*(.-)\n\n"),
         "Each pitfall must have an external reference"
      )
      local found = false
      for key in context:gmatch("%]%[([^%]]+)%]") do
         assert(definitions[key], "Missing external reference: " .. key)
         found = true
      end
      assert(found, "External references must resolve to HTTPS sources")
      count = count + 1
   end
   assert(count == 208, "Review the complete pitfall inventory")
   print(string.format("References: %d pitfalls passed.", count))
end

-- This executable example explicitly qualifies Linux ELF, Clang and GCC.
assert(not platform.is_windows, "The documented example profile is Linux ELF")
local temporary = platform.temporary_directory()
local success, failure = xpcall(function()
   local directory = temporary .. "/examples"
   local sources = {}
   local seen = {}
   local count = 0
   for _, name in ipairs(documents) do
      local source = read("docs/code_style/c_language/" .. name)
      if name == "c-common-pitfalls.md" then
         references(source)
      end
      for relative, language, code in
         source:gmatch(
            "<!%-%- example%-file: ([^\n]+) %-%->%s*```([^\n]+)\n(.-)\n```"
         )
      do
         -- CWE-22: markers cannot escape or overwrite another named example.
         assert(relative:match("^[%w_./-]+$"), "Invalid example path")
         assert(not relative:match("^/"), "Absolute example path")
         assert(not relative:find("..", 1, true), "Parent example path")
         assert(not seen[relative], "Duplicate example path")
         seen[relative] = true
         count = count + 1
         local path = directory .. "/" .. relative
         local parent = assert(path:match("^(.*)/[^/]+$"))
         platform.run({ "mkdir", "-p", "--", parent })
         write(path, code .. "\n")
         if language == "c" then
            local formatted = assert(platform.command_output({
               formatter,
               "--style=file:tools/lint/code/c/.clang-format",
               path,
            }))
            local display = formatted:gsub("\t", string.rep(" ", 8))
            assert(display == code .. "\n", "C formatting drift: " .. path)
            write(path, formatted)
            if relative:match("%.c$") then
               sources[#sources + 1] = path
            end
         end
      end
   end
   assert(count == 24 and #sources == 9, "Review the example file inventory")
   -- Small fixtures share one runner; each build uses bounded parallel jobs.
   local profiles = {
      { "clang", "OFF" },
      { "gcc", "OFF" },
      { "clang", "ON" },
   }
   for index, profile in ipairs(profiles) do
      local build = temporary .. "/build-" .. index
      platform.run({
         "cmake",
         "-S",
         directory,
         "-B",
         build,
         "-DCMAKE_C_COMPILER=" .. profile[1],
         "-DCMAKE_BUILD_TYPE=Release",
         "-DSAMPLE_SANITIZE=" .. profile[2],
      })
      platform.run({ "cmake", "--build", build, "--parallel", "2" })
      platform.run({
         "ctest",
         "--test-dir",
         build,
         "--output-on-failure",
         "--timeout",
         "30",
      })
   end
   local arguments = {
      tidy,
      "--experimental-custom-checks",
      "--config-file=tools/lint/code/c/.clang-tidy",
      "-p",
      temporary .. "/build-1",
   }
   for _, source in ipairs(sources) do
      arguments[#arguments + 1] = source
   end
   platform.run(arguments)
   print("Complete C examples passed formatting, builds, tests and analysis.")
end, debug.traceback)
platform.remove_temporary_directory(temporary)
assert(success, failure)

-- EOF
