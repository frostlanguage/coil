-- SPDX-FileCopyrightText: © 2026 Rafael V. Volkmer <rafael.v.volkmer@gmail.com>
-- SPDX-License-Identifier: GPL-3.0-only

--- Generic ordered boolean-policy state for Lua tooling.

local M = {}

--- Parse a strict textual boolean.
-- @param value string|nil: textual boolean value.
-- @return boolean|nil: parsed value, or nil for invalid input.
function M.parse_boolean(value)
   if value == "true" or value == "1" then
      return true
   end

   if value == "false" or value == "0" or value == nil then
      return false
   end

   return nil
end

--- Create an ordered boolean policy set.
-- @param keys table: ordered policy keys.
-- @return table: policy state object.
function M.new(keys)
   local order = {}
   local values = {}

   for _, key in ipairs(keys) do
      if values[key] ~= nil then
         error("duplicate policy key: " .. tostring(key), 2)
      end

      order[#order + 1] = key
      values[key] = false
   end

   local state = {}

   --- Mark one policy key true.
   -- @param key string: known policy key.
   function state.mark(key)
      if values[key] == nil then
         error("unknown policy key: " .. tostring(key), 2)
      end
      values[key] = true
   end

   --- Mark every policy key true.
   function state.mark_all()
      for _, key in ipairs(order) do
         values[key] = true
      end
   end

   --- Read one policy key.
   -- @param key string: known policy key.
   -- @return boolean: current policy value.
   function state.get(key)
      if values[key] == nil then
         error("unknown policy key: " .. tostring(key), 2)
      end
      return values[key]
   end

   --- Iterate policy keys in their declared order.
   -- @return function: iterator yielding key and boolean value.
   function state.each()
      local index = 0
      return function()
         index = index + 1
         local key = order[index]
         if not key then
            return nil
         end
         return key, values[key]
      end
   end

   return state
end

return M

-- EOF
