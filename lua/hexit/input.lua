local motion = require('hexit.motion')
local view = require('hexit.view')

local M = {}
local actions = {
  h = 'Left', l = 'Right', k = 'Up', j = 'Down',
  w = 'WordNext', b = 'WordPrev', e = 'WordEnd',
  G = 'Last', ['$'] = 'RowEnd', g = 'GPrefix',
  ['0'] = 'Digit0', ['\t'] = 'SwitchArea',
}
local specials = {
  ['<Left>'] = 'Left', ['<Right>'] = 'Right', ['<Up>'] = 'Up', ['<Down>'] = 'Down',
  ['<C-u>'] = 'HalfUp', ['<C-d>'] = 'HalfDown', ['<C-b>'] = 'PageUp', ['<C-f>'] = 'PageDown',
  ['<Tab>'] = 'SwitchArea', ['<Esc>'] = 'Escape',
  ['<ScrollWheelUp>'] = 'WheelUp', ['<ScrollWheelDown>'] = 'WheelDown',
}
local names = {
  Left = true, Right = true, Up = true, Down = true, WordNext = true,
  WordPrev = true, WordEnd = true, First = true, Last = true,
  RowStart = true, RowEnd = true, HalfUp = true, HalfDown = true,
  PageUp = true, PageDown = true, SwitchArea = true, Escape = true,
  GPrefix = true, WheelUp = true, WheelDown = true,
}
for digit = 0, 9 do names['Digit' .. digit] = true end

local function message(text)
  vim.notify('hexit: ' .. text, vim.log.levels.WARN)
end

local function dispatch(session, action, key)
  if session.phase ~= 'ready' then
    message('wait until the binary snapshot is ready')
    return
  end
  local state = session.input
  if action == 'Escape' then
    state.count, state.prefix = nil, nil
    motion.cancel(session)
    return
  end
  if state.prefix then
    state.prefix = nil
    if key == 'g' then
      action = 'First'
    else
      state.count = nil
      message('expected second g')
      return
    end
  elseif action == 'GPrefix' then
    state.prefix = 'g'
    return
  elseif action and action:match('^Digit%d$') then
    local digit = tonumber(action:sub(-1))
    if digit == 0 and state.count == nil then
      action = 'RowStart'
    else
      local current = state.count or 0
      if current > math.floor((2147483647 - digit) / 10) then
        state.count = nil
        message('count exceeds 2147483647')
        return
      end
      state.count = current * 10 + digit
      return
    end
  end
  local count, has_count = state.count or 1, state.count ~= nil
  state.count = nil
  if not action or action:match('^Char%x%x$') then
    message('operation not supported in the first stage')
    return
  end
  if action == 'SwitchArea' then
    if session.root.size == 0 then return end
    if session.cursor.area == 'hex' then
      if not session.options.show_ascii then message('ASCII area is hidden'); return end
      session.cursor.area, session.cursor.nibble = 'ascii', 0
    else
      session.cursor.area, session.cursor.nibble = 'hex', 0
    end
    session.preferred_col = nil
    view.render(session)
  elseif action == 'WheelUp' or action == 'WheelDown' then
    view.scroll(session, action == 'WheelUp' and -3 or 3)
  else
    motion.cancel(session)
    motion.move(session, action, count, has_count, session.height, function()
      if session.phase == 'ready' then view.render(session) end
    end)
  end
end

function M.attach(session)
  local buf = session.bufnr
  session.input = { count = nil, prefix = nil }
  local function plug(action, key)
    local name = '<Plug>(Hexit-' .. action .. ')'
    vim.keymap.set('n', name, function() dispatch(session, action, key) end,
      { buffer = buf, silent = true, nowait = true })
    return name
  end
  for action in pairs(names) do plug(action, action == 'GPrefix' and 'g' or nil) end
  local char_names = {}
  for code = 32, 126 do
    local key = string.char(code)
    if key ~= ':' and not actions[key] then
      local action = ('Char%02X'):format(code)
      char_names[key] = plug(action, key)
    end
  end
  if session.options.mappings then
    for key, action in pairs(actions) do
      if key ~= '\t' then
        vim.keymap.set('n', key, '<Plug>(Hexit-' .. action .. ')',
          { buffer = buf, silent = true, nowait = true, remap = true })
      end
    end
    for key, name in pairs(char_names) do
      vim.keymap.set('n', key == '<' and '<lt>' or key, name,
        { buffer = buf, silent = true, nowait = true, remap = true })
    end
    for key, action in pairs(specials) do
      vim.keymap.set('n', key, '<Plug>(Hexit-' .. action .. ')',
        { buffer = buf, silent = true, nowait = true, remap = true })
    end
    for digit = 1, 9 do
      vim.keymap.set('n', tostring(digit), '<Plug>(Hexit-Digit' .. digit .. ')',
        { buffer = buf, silent = true, nowait = true, remap = true })
    end
  end
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = session.augroup, buffer = buf,
    callback = function() session.input.count, session.input.prefix = nil, nil; motion.cancel(session) end,
  })
end

return M
