local M = {}

local defaults = {
  bytes_per_row = 16,
  byte_group_size = 1,
  uppercase_hex = true,
  show_ascii = true,
  show_offset = true,
  default_copy_format = 'hex',
  search_ignorecase = nil,
  search_smartcase = nil,
  mappings = true,
}

local formats = {
  hex = true, compact = true, escaped = true, c = true, cstring = true,
  python = true, rust = true, ascii = true, base64 = true,
}

local function validate(key, value)
  if key == 'bytes_per_row' then
    return value == 8 or value == 16 or value == 32 or value == 'auto'
  elseif key == 'byte_group_size' then
    return value == 1 or value == 2 or value == 4
  elseif key == 'default_copy_format' then
    return formats[value] == true
  elseif key == 'search_ignorecase' or key == 'search_smartcase' then
    return type(value) == 'boolean'
  end
  return type(value) == 'boolean'
end

function M.merge(opts)
  if opts ~= nil and type(opts) ~= 'table' then
    error('hexit: setup expects a table', 2)
  end
  local result = vim.deepcopy(defaults)
  for key, value in pairs(opts or {}) do
    if defaults[key] == nil and key ~= 'search_ignorecase' and key ~= 'search_smartcase' then
      error('hexit: unknown option ' .. tostring(key), 2)
    end
    if not validate(key, value) then
      error('hexit: invalid value for ' .. key, 2)
    end
    result[key] = value
  end
  return result
end

return M
