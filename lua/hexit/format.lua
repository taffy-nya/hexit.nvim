-- Pure byte-to-text encoders used by Copy As.
--
-- `new(name)` returns an encoder with `push(bytes)` and `finish()`. Chunks may
-- have any size; `finish()` returns the complete text without a trailing
-- newline. `encode(name, bytes)` is the one-shot convenience interface.
local M = {}

local concat = table.concat
local gsub = string.gsub
local byte = string.byte
local sub = string.sub

local uppercase = '0123456789ABCDEF'
local lowercase = '0123456789abcdef'

local function make_map(transform)
  local map = {}
  for value = 0, 255 do
    map[value + 1] = transform(value)
  end
  return map
end

local function hex_map(digits)
  return make_map(function(value)
    local high = math.floor(value / 16) + 1
    local low = value % 16 + 1
    return digits:sub(high, high) .. digits:sub(low, low)
  end)
end

local hex_upper = hex_map(uppercase)
local hex_lower = hex_map(lowercase)
local escaped_upper = make_map(function(value)
  return '\\x' .. hex_upper[value + 1]
end)
local escaped_lower = make_map(function(value)
  return '\\x' .. hex_lower[value + 1]
end)
local c_upper = make_map(function(value)
  return '0x' .. hex_upper[value + 1]
end)
local c_lower = make_map(function(value)
  return '0x' .. hex_lower[value + 1]
end)
local ascii = make_map(function(value)
  if value >= 0x20 and value <= 0x7e then return string.char(value) end
  return '.'
end)

local definitions = {
  hex = { map = hex_upper, separator = ' ' },
  compact = { map = hex_upper },
  escaped = { map = escaped_upper },
  c = { map = c_upper, separator = ', ', prefix = '{ ', suffix = ' }', empty = '{ }' },
  cstring = { map = escaped_upper, prefix = '"', suffix = '"' },
  python = { map = escaped_lower, prefix = 'b"', suffix = '"' },
  rust = { map = c_lower, separator = ', ', prefix = '[', suffix = ']' },
  ascii = { map = ascii },
  base64 = { base64 = true },
}

local Encoder = {}
Encoder.__index = Encoder

function Encoder:push(bytes)
  if self.finished then error('format: cannot push after finish', 2) end
  if type(bytes) ~= 'string' then error('format: chunk must be a string', 2) end
  if #bytes == 0 then return self end

  if self.definition.base64 then
    local start = 1
    local tail = self.tail
    if #tail > 0 then
      local needed = 3 - #tail
      if #bytes < needed then
        self.tail = tail .. bytes
        return self
      end
      self.parts[#self.parts + 1] =
        vim.base64.encode(tail .. sub(bytes, 1, needed))
      start = needed + 1
    end

    local remaining = #bytes - start + 1
    local aligned = remaining - (remaining % 3)
    if aligned > 0 then
      local block = start == 1 and aligned == #bytes
        and bytes or sub(bytes, start, start + aligned - 1)
      self.parts[#self.parts + 1] = vim.base64.encode(block)
    end
    local tail_start = start + aligned
    self.tail = tail_start <= #bytes and sub(bytes, tail_start) or ''
    return self
  end

  local first = not self.has_data
  local map = self.definition.map
  local separator = self.definition.separator
  local encoded = gsub(bytes, '.', function(char)
    local item = map[byte(char) + 1]
    if first then
      first = false
      return item
    end
    return separator and (separator .. item) or item
  end)
  self.has_data = true
  self.parts[#self.parts + 1] = encoded
  return self
end

function Encoder:finish()
  if self.finished then return self.result end

  if self.definition.base64 and #self.tail > 0 then
    self.parts[#self.parts + 1] = vim.base64.encode(self.tail)
    self.tail = ''
  end

  if not self.has_data and self.definition.empty then
    self.result = self.definition.empty
  else
    if self.definition.suffix then
      self.parts[#self.parts + 1] = self.definition.suffix
    end
    self.result = concat(self.parts)
  end
  self.finished = true
  return self.result
end

function M.new(name)
  local definition = definitions[name]
  if not definition then
    error(('format: unknown format %q'):format(tostring(name)), 2)
  end
  local encoder = setmetatable({
    definition = definition,
    parts = {},
    tail = '',
    has_data = false,
    finished = false,
  }, Encoder)
  if definition.prefix then encoder.parts[1] = definition.prefix end
  return encoder
end

function M.encode(name, bytes)
  if type(bytes) ~= 'string' then error('format: bytes must be a string', 2) end
  return M.new(name):push(bytes):finish()
end

return M
