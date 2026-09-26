local motion = require('hexit.motion')
local view = require('hexit.view')
local actions = require('hexit.actions')

local M = {}
local defaults = {
  h = 'Left', l = 'Right', k = 'Up', j = 'Down', w = 'WordNext', b = 'WordPrev', e = 'WordEnd',
  G = 'Last', ['$'] = 'RowEnd', g = 'GPrefix', v = 'Visual', V = 'VisualLine',
  r = 'Replace', R = 'ReplaceMode', y = 'Yank', p = 'PasteAfter', P = 'PasteBefore', u = 'Undo',
}
local specials = {
  ['<Left>'] = 'Left', ['<Right>'] = 'Right', ['<Up>'] = 'Up', ['<Down>'] = 'Down',
  ['<C-u>'] = 'HalfUp', ['<C-d>'] = 'HalfDown', ['<C-b>'] = 'PageUp', ['<C-f>'] = 'PageDown',
  ['<C-e>'] = 'Unsupported', ['<C-y>'] = 'Unsupported', ['<C-r>'] = 'Redo',
  ['<Tab>'] = 'SwitchArea', ['<Esc>'] = 'Escape',
  ['<ScrollWheelUp>'] = 'WheelUp', ['<ScrollWheelDown>'] = 'WheelDown',
}
local names = {
  Left = true, Right = true, Up = true, Down = true, WordNext = true, WordPrev = true,
  WordEnd = true, First = true, Last = true, RowStart = true, RowEnd = true,
  HalfUp = true, HalfDown = true, PageUp = true, PageDown = true, SwitchArea = true,
  Escape = true, GPrefix = true, WheelUp = true, WheelDown = true, Unsupported = true,
  Visual = true, VisualLine = true, Replace = true, ReplaceMode = true, Yank = true,
  PasteAfter = true, PasteBefore = true, Undo = true, Redo = true,
}
for digit = 0, 9 do names['Digit' .. digit] = true end

local function message(text)
  vim.notify('hexit: ' .. text, vim.log.levels.WARN)
end
local function clear_pending(state)
  state.count, state.prefix, state.overflow = nil, nil, nil
end

local function temp_keys()
  local keys = {}
  for code = 32, 126 do keys[#keys + 1] = string.char(code) end
  for _, key in ipairs({
    '<Esc>', '<BS>', '<Tab>', '<Left>', '<Right>', '<Up>', '<Down>',
    '<C-r>', '<C-u>', '<C-d>', '<C-b>', '<C-f>', '<C-e>', '<C-y>',
    '<ScrollWheelUp>', '<ScrollWheelDown>',
  }) do
    keys[#keys + 1] = key
  end
  return keys
end
local captured = temp_keys()
local function canonical(key) return key == '<' and '<lt>' or key end

local function clear_temporary(session)
  local state = session.input
  if not state or not state.temporary then return end
  local previous = state.temporary
  state.temporary = nil
  for _, key in ipairs(captured) do
    pcall(vim.keymap.del, 'n', canonical(key), { buffer = session.bufnr })
    local original = previous[key]
    if original and next(original) then vim.fn.mapset('n', false, original) end
  end
end
M.clear_temporary = clear_temporary

local function valid_input(session, key, byte)
  if #key ~= 1 or key:byte() < 32 or key:byte() > 126 then return false end
  if byte then return key:match('^[%da-fA-F]$') ~= nil end
  return true
end

local function receive(session, key)
  local state = session.input
  if session.phase ~= 'ready' then message('wait until the binary save finishes'); return end
  if key == ':' and session.cursor.area == 'hex' then
    clear_temporary(session)
    state.replace, state.first, state.second_pending, state.replace_count = nil, nil, nil, nil
    if session.mode == 'replace' then actions.escape(session) end
    vim.api.nvim_feedkeys(':', 'nit', false)
    return
  end
  if key == '<Esc>' then
    clear_temporary(session)
    state.replace, state.first, state.second_pending, state.replace_count = nil, nil, nil, nil
    actions.escape(session)
    return
  end
  if session.pending then message('wait for edit comparison to finish'); return end
  if state.replace == 'mode' then
    if not valid_input(session, key, session.cursor.area == 'hex') then
      message('replace mode accepts only ' .. (session.cursor.area == 'hex' and 'hex digits' or 'printable ASCII'))
      return
    end
    local ok, err = actions.replace_mode(session, key)
    if not ok then message(err) end
    return
  end
  if not valid_input(session, key, session.cursor.area == 'hex') then
    state.replace, state.first, state.second_pending, state.replace_count = nil, nil, nil, nil
    clear_temporary(session)
    message('invalid replacement input')
    return
  end
  if state.replace == 'visual_hex' then
    state.first = state.first or key
    if state.first == key and not state.second_pending then
      state.second_pending = true
      view.render(session)
      return
    end
    -- The second digit may equal the first one.
    local value = state.first .. key
    state.first, state.second_pending, state.replace = nil, nil, nil
    clear_temporary(session)
    local ok, err = actions.replace(session, value, 1)
    if not ok then message(err) end
    return
  end
  local count = state.replace_count or 1
  state.replace, state.replace_count = nil, nil
  clear_temporary(session)
  local ok, err = actions.replace(session, key, count)
  if not ok then message(err) end
end

local function temporary(session)
  local saved = {}
  for _, key in ipairs(captured) do
    local lhs = canonical(key)
    local original = vim.fn.maparg(lhs, 'n', false, true)
    saved[key] = original
    vim.keymap.set('n', lhs, function() receive(session, key) end,
      { buffer = session.bufnr, silent = true, nowait = true })
  end
  session.input.temporary = saved
end

local navigation = {
  Left = true, Right = true, Up = true, Down = true,
  WordNext = true, WordPrev = true, WordEnd = true,
  First = true, Last = true, RowStart = true, RowEnd = true,
  HalfUp = true, HalfDown = true, PageUp = true, PageDown = true,
  WheelUp = true, WheelDown = true, SwitchArea = true,
  Visual = true, VisualLine = true, Yank = true, Escape = true, GPrefix = true,
}
for digit = 0, 9 do navigation['Digit' .. digit] = true end

local function dispatch(session, action, key)
  if session.phase ~= 'ready' and session.phase ~= 'saving' then
    message('wait until the binary snapshot is ready')
    return
  end
  if session.phase == 'saving' and not navigation[action] then
    message('wait until the binary save finishes')
    return
  end
  if session.pending and (action == 'Replace' or action == 'ReplaceMode'
    or action == 'PasteAfter' or action == 'PasteBefore'
    or action == 'Undo' or action == 'Redo') then
    message('wait for edit comparison to finish')
    return
  end
  local state = session.input
  if state.replace then
    if action == 'Escape' then
      receive(session, '<Esc>')
    else
      message('finish replacement with Esc before navigating')
    end
    return
  end
  if action == 'Escape' then
    clear_pending(state)
    motion.cancel(session)
    actions.escape(session)
    return
  end
  if state.prefix then
    state.prefix = nil
    if key == 'g' then action = 'First' else clear_pending(state); message('expected second g'); return end
  elseif action == 'GPrefix' then
    state.prefix = 'g'
    return
  elseif action and action:match('^Digit%d$') then
    local digit = tonumber(action:sub(-1))
    if state.overflow then return end
    if digit == 0 and state.count == nil then
      action = 'RowStart'
    else
      local current = state.count or 0
      if current > math.floor((2147483647 - digit) / 10) then
        state.count, state.overflow = nil, true
        message('count exceeds 2147483647')
        return
      end
      state.count = current * 10 + digit
      return
    end
  end
  if state.overflow then state.count, state.overflow = nil, nil; return end
  local count, has_count = state.count or 1, state.count ~= nil
  state.count = nil
  if not action or action == 'Unsupported' or action:match('^Char%x%x$') then
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
  elseif action == 'Visual' or action == 'VisualLine' then
    actions.visual(session, action == 'Visual' and 'visual' or 'visual_line')
  elseif action == 'Replace' or action == 'ReplaceMode' then
    if session.root.size == 0 then message('cannot replace an empty file'); return end
    if action == 'ReplaceMode' and (has_count or session.anchor) then
      message('counted or Visual R is not supported')
      return
    end
    if action == 'ReplaceMode' then
      session.mode = 'replace'
      session.eof_after_replace = false
      actions.begin(session)
      state.replace = 'mode'
    else
      state.replace = session.anchor and (session.cursor.area == 'hex' and 'visual_hex' or 'single') or 'single'
      state.replace_count = count
    end
    temporary(session)
    view.render(session)
  elseif action == 'Yank' then
    local ok, err = actions.yank(session, count)
    if not ok then message(err) end
  elseif action == 'PasteAfter' or action == 'PasteBefore' then
    local ok, err = actions.paste(session, action == 'PasteAfter', count)
    if not ok then message(err) end
  elseif action == 'Undo' or action == 'Redo' then
    actions.history(session, action == 'Redo', count)
  else
    motion.cancel(session)
    motion.move(session, action, count, has_count, session.owner_height, function()
      if session.phase == 'ready' or session.phase == 'saving' then view.render(session) end
    end)
    if session.anchor then view.render(session) end
  end
end

function M.attach(session)
  local buf = session.bufnr
  session.input = { count = nil, prefix = nil, overflow = nil }
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
    if key ~= ':' and not defaults[key] then
      local action = ('Char%02X'):format(code)
      char_names[key] = plug(action, key)
    end
  end
  if session.options.mappings then
    for key, action in pairs(defaults) do
      vim.keymap.set('n', key, '<Plug>(Hexit-' .. action .. ')',
        { buffer = buf, silent = true, nowait = true, remap = true })
    end
    for key, name in pairs(char_names) do
      vim.keymap.set('n', canonical(key), name,
        { buffer = buf, silent = true, nowait = true, remap = true })
    end
    for key, action in pairs(specials) do
      vim.keymap.set('n', key, '<Plug>(Hexit-' .. action .. ')',
        { buffer = buf, silent = true, nowait = true, remap = true })
    end
    vim.keymap.set('n', '0', '<Plug>(Hexit-Digit0)',
      { buffer = buf, silent = true, nowait = true, remap = true })
    for digit = 1, 9 do
      vim.keymap.set('n', tostring(digit), '<Plug>(Hexit-Digit' .. digit .. ')',
        { buffer = buf, silent = true, nowait = true, remap = true })
    end
  end
  vim.api.nvim_create_autocmd('CmdlineEnter', {
    group = session.augroup, pattern = ':',
    callback = function()
      if vim.api.nvim_get_current_buf() == buf then
        clear_pending(session.input)
        motion.cancel(session)
        if session.input.replace then
          clear_temporary(session)
          session.input.replace, session.input.first, session.input.second_pending = nil, nil, nil
          if session.mode == 'replace' then actions.escape(session) end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    group = session.augroup, buffer = buf,
    callback = function()
      clear_pending(session.input)
      motion.cancel(session)
      if session.input.replace then
        clear_temporary(session)
        session.input.replace, session.input.first, session.input.second_pending = nil, nil, nil
        if session.mode == 'replace' then actions.escape(session) end
      end
    end,
  })
end

return M
