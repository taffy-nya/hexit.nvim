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

M.default_keys = {
  h = 'Left', l = 'Right', k = 'Up', j = 'Down', w = 'WordNext', b = 'WordPrev', e = 'WordEnd',
  G = 'Last', ['$'] = 'RowEnd', g = 'GPrefix', v = 'Visual', V = 'VisualLine',
  r = 'Replace', R = 'ReplaceMode', y = 'Yank', p = 'PasteAfter', P = 'PasteBefore', u = 'Undo',
  ['/'] = 'SearchForward', ['?'] = 'SearchBackward', n = 'SearchNext', N = 'SearchPrev',
}
M.special_keys = {
  ['<Left>'] = 'Left', ['<Right>'] = 'Right', ['<Up>'] = 'Up', ['<Down>'] = 'Down',
  ['<C-u>'] = 'HalfUp', ['<C-d>'] = 'HalfDown', ['<C-b>'] = 'PageUp', ['<C-f>'] = 'PageDown',
  ['<C-e>'] = 'Unsupported', ['<C-y>'] = 'Unsupported', ['<C-r>'] = 'Redo',
  ['<Tab>'] = 'SwitchArea', ['<Esc>'] = 'Escape',
  ['<ScrollWheelUp>'] = 'WheelUp', ['<ScrollWheelDown>'] = 'WheelDown',
}
M.action_names = { First = true, RowStart = true }
for _, action in pairs(M.default_keys) do M.action_names[action] = true end
for _, action in pairs(M.special_keys) do M.action_names[action] = true end
for digit = 0, 9 do M.action_names['Digit' .. digit] = true end

function M.mapping_lhs(lhs)
  return vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, true, true))
end

local function merge_mappings(value)
  if type(value) == 'boolean' then return value end
  if type(value) ~= 'table' then error('hexit: mappings must be a boolean or table', 3) end
  if value.defaults ~= nil and type(value.defaults) ~= 'boolean' then
    error('hexit: mappings.defaults must be a boolean', 3)
  end
  local result = { defaults = value.defaults ~= false }
  for lhs, action in pairs(value) do
    if lhs ~= 'defaults' then
      if type(lhs) ~= 'string' or lhs == '' then
        error('hexit: mapping keys must be nonempty strings', 3)
      end
      if action ~= false and (type(action) ~= 'string' or not M.action_names[action]) then
        error('hexit: invalid mapping action for ' .. lhs, 3)
      end
      local key = M.mapping_lhs(lhs)
      if key == '' then error('hexit: mapping keys must be nonempty strings', 3) end
      if key == 'defaults' or result[key] ~= nil then
        error('hexit: duplicate or reserved mapping key ' .. lhs, 3)
      end
      result[key] = action
    end
  end
  return result
end

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
    if key == 'mappings' then
      result[key] = merge_mappings(value)
    else
      if not validate(key, value) then
        error('hexit: invalid value for ' .. key, 2)
      end
      result[key] = value
    end
  end
  return result
end

return M
