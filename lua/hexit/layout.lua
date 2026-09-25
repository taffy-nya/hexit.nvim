local document = require('hexit.document')

local M = {}
local MAX_SAFE_INTEGER = 9007199254740991
local floor = math.floor
local min = math.min
local concat = table.concat
local sub = string.sub
local byte = string.byte
local char = string.char
local digits_upper = '0123456789ABCDEF'
local digits_lower = '0123456789abcdef'
local hex_upper, hex_lower, ascii = {}, {}, {}

for value = 0, 255 do
  local high = floor(value / 16)
  local low = value % 16
  hex_upper[value + 1] = sub(digits_upper, high + 1, high + 1) .. sub(digits_upper, low + 1, low + 1)
  hex_lower[value + 1] = sub(digits_lower, high + 1, high + 1) .. sub(digits_lower, low + 1, low + 1)
  ascii[value + 1] = value >= 0x20 and value <= 0x7e and char(value) or '.'
end

local function require_integer(value, name)
  if type(value) ~= 'number' or value < 0 or value > MAX_SAFE_INTEGER or floor(value) ~= value then
    error(('layout: %s must be a non-negative safe integer'):format(name), 3)
  end
end

local function format_hex(value, uppercase)
  local digits = uppercase and digits_upper or digits_lower
  if value == 0 then return '0' end

  local result = {}
  while value > 0 do
    local digit = value % 16
    result[#result + 1] = sub(digits, digit + 1, digit + 1)
    value = floor(value / 16)
  end
  for i = 1, floor(#result / 2) do
    local opposite = #result - i + 1
    result[i], result[opposite] = result[opposite], result[i]
  end
  return concat(result)
end
local function hex_digit_count(value)
  local count = 1
  while value >= 16 do
    value = floor(value / 16)
    count = count + 1
  end
  return count
end


local function rendered_width(bpr, group, offset_width, show_offset, show_ascii)
  local prefix_width = show_offset and offset_width + 2 or 0
  local hex_width = 2 * bpr + floor((bpr - 1) / group)
  return prefix_width + hex_width + (show_ascii and 2 + bpr or 0)
end

function M.compute(opts, width, size)
  opts = opts or {}
  require_integer(width, 'width')
  require_integer(size, 'size')

  local group = opts.byte_group_size or 1
  if group ~= 1 and group ~= 2 and group ~= 4 then
    error('layout: byte_group_size must be 1, 2, or 4', 2)
  end

  local uppercase = opts.uppercase_hex
  if uppercase == nil then uppercase = true end
  local show_ascii = opts.show_ascii
  if show_ascii == nil then show_ascii = true end
  local show_offset = opts.show_offset
  if show_offset == nil then show_offset = true end
  if type(uppercase) ~= 'boolean' or type(show_ascii) ~= 'boolean' or type(show_offset) ~= 'boolean' then
    error('layout: display options must be booleans', 2)
  end

  local offset_width = math.max(8, hex_digit_count(math.max(size - 1, 0)))
  local bpr = opts.bytes_per_row
  if bpr == nil then bpr = 16 end
  if bpr == 'auto' then
    bpr = 8
    if rendered_width(16, group, offset_width, show_offset, show_ascii) <= width then
      bpr = 16
    end
    if rendered_width(32, group, offset_width, show_offset, show_ascii) <= width then
      bpr = 32
    end
  elseif bpr ~= 8 and bpr ~= 16 and bpr ~= 32 then
    error('layout: bytes_per_row must be 8, 16, 32, or "auto"', 2)
  end

  local hex_width = 2 * bpr + floor((bpr - 1) / group)
  local prefix_width = show_offset and offset_width + 2 or 0
  local hex_start = prefix_width
  local ascii_start = hex_start + hex_width + 2

  return {
    bpr = bpr,
    hex_start = hex_start,
    ascii_start = ascii_start,
    offset_width = offset_width,
    group = group,
    width = rendered_width(bpr, group, offset_width, show_offset, show_ascii),
    hex_width = hex_width,
    uppercase_hex = uppercase,
    show_ascii = show_ascii,
    show_offset = show_offset,
  }
end

function M.row(root, row_index, layout)
  require_integer(row_index, 'row_index')
  local bpr = layout.bpr
  local start = row_index * bpr
  if (root.size == 0 and row_index ~= 0) or (root.size > 0 and start >= root.size) then
    return ''
  end
  local available = min(bpr, root.size - start)
  local data = available > 0 and document.read(root, start, available) or ''
  local parts = {}

  if layout.show_offset then
    local offset = format_hex(start, layout.uppercase_hex)
    parts[#parts + 1] = string.rep('0', math.max(0, layout.offset_width - #offset))
    parts[#parts + 1] = offset
    parts[#parts + 1] = '  '
  end

  if root.size == 0 and row_index == 0 then
    parts[#parts + 1] = '(empty)'
    parts[#parts + 1] = string.rep(' ', layout.hex_width - 7)
  else
    local hex_bytes = layout.uppercase_hex and hex_upper or hex_lower
    for byte_col = 0, bpr - 1 do
      if byte_col > 0 and byte_col % layout.group == 0 then
        parts[#parts + 1] = ' '
      end
      local value = byte(data, byte_col + 1)
      parts[#parts + 1] = value and hex_bytes[value + 1] or '  '
    end
  end

  if layout.show_ascii then
    parts[#parts + 1] = '  '
    for byte_col = 0, bpr - 1 do
      local value = byte(data, byte_col + 1)
      parts[#parts + 1] = value and ascii[value + 1] or ' '
    end
  end

  return concat(parts)
end

function M.cell(layout, byte_col, nibble, area)
  if type(byte_col) ~= 'number' or byte_col < 0 or byte_col >= layout.bpr or floor(byte_col) ~= byte_col then
    return nil
  end
  if area == 'ascii' then
    if not layout.show_ascii then return nil end
    return layout.ascii_start + byte_col
  end
  if area ~= 'hex' or (nibble ~= 0 and nibble ~= 1) then return nil end
  return layout.hex_start + 2 * byte_col + floor(byte_col / layout.group) + nibble
end

local function cursor_at(row_start, byte_col, nibble, area, size)
  local offset = row_start + byte_col
  if offset >= size then return nil end
  return { offset = offset, nibble = nibble, area = area }
end

function M.hit(layout, line, col, top_row, size)
  if type(line) ~= 'number' or line < 2 or floor(line) ~= line
    or type(col) ~= 'number' or col < 0 or floor(col) ~= col then
    return nil
  end
  require_integer(top_row, 'top_row')
  require_integer(size, 'size')
  if size == 0 then return nil end

  local row_index = top_row + line - 2
  local row_start = row_index * layout.bpr
  if row_start > MAX_SAFE_INTEGER then return nil end

  local hex_col = col - layout.hex_start
  if hex_col >= 0 and hex_col < layout.hex_width then
    for byte_col = 0, layout.bpr - 1 do
      local byte_start = 2 * byte_col + floor(byte_col / layout.group)
      if hex_col == byte_start then
        return cursor_at(row_start, byte_col, 0, 'hex', size)
      elseif hex_col == byte_start + 1 then
        return cursor_at(row_start, byte_col, 1, 'hex', size)
      elseif byte_col + 1 < layout.bpr and (byte_col + 1) % layout.group == 0
        and hex_col == byte_start + 2 then
        return cursor_at(row_start, byte_col, 1, 'hex', size)
      end
    end
    return nil
  end

  if layout.show_ascii then
    local ascii_col = col - layout.ascii_start
    if ascii_col >= 0 and ascii_col < layout.bpr then
      return cursor_at(row_start, ascii_col, 0, 'ascii', size)
    end
  end
  return nil
end

return M
