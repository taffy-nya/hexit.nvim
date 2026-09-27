local motion = require('hexit.motion')
local view = require('hexit.view')
local actions = require('hexit.actions')
local search = require('hexit.search')
local messages = require('hexit.message')
local status = require('hexit.status')

local M = {}
local defaults = {
  h = 'Left', l = 'Right', k = 'Up', j = 'Down', w = 'WordNext', b = 'WordPrev', e = 'WordEnd',
  G = 'Last', ['$'] = 'RowEnd', g = 'GPrefix', v = 'Visual', V = 'VisualLine',
  r = 'Replace', R = 'ReplaceMode', y = 'Yank', p = 'PasteAfter', P = 'PasteBefore', u = 'Undo',
  ['/'] = 'SearchForward', ['?'] = 'SearchBackward', n = 'SearchNext', N = 'SearchPrev',
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
  SearchForward = true, SearchBackward = true, SearchNext = true, SearchPrev = true,
}
for digit = 0, 9 do names['Digit' .. digit] = true end

local function message(text, level)
  messages.show(text, level)
end
local function clear_pending(state)
  state.count, state.prefix, state.overflow = nil, nil, nil
end
local bridge
local commandline_group

local function set_search_kind(session, kind)
  local state = session.input
  if not state or state.search_kind == kind then return end
  state.search_kind = kind
  status.changed(session)
end

local function clear_search_kind(session)
  if session.input and session.input.search_kind ~= nil then
    session.input.search_kind = nil
    status.changed(session)
  end
end

local function next_search_token(session)
  local state = session.input
  state.search_token = (state.search_token or 0) + 1
  return state.search_token
end

local function restore_search_options(context)
  local saved = context.options
  if not saved or saved.restored then return end
  saved.restored = true

  local ok, value = pcall(function() return vim.o.incsearch end)
  if ok and value == false then
    pcall(function() vim.o.incsearch = saved.incsearch end)
  end
  ok, value = pcall(function() return vim.o.hlsearch end)
  if ok and value == false then
    pcall(function() vim.o.hlsearch = saved.hlsearch end)
  end

  local state_ok, hlsearch = pcall(function() return vim.v.hlsearch end)
  if state_ok and (hlsearch == 0 or hlsearch == false) then
    local was_enabled = saved.hlsearch_state == true or saved.hlsearch_state == 1
    pcall(vim.cmd, 'let v:hlsearch = ' .. (was_enabled and '1' or '0'))
  end
end

function M.invalidate_search(session)
  if not session or not session.input then return end
  next_search_token(session)
  if bridge and bridge.session == session then
    bridge.valid = false
    restore_search_options(bridge)
    clear_search_kind(session)
    if not bridge.active then bridge = nil end
  else
    clear_search_kind(session)
  end
end

local function current_session()
  return require('hexit.session').get(vim.api.nvim_get_current_buf())
end

local function make_search_context(session, direction, count, kind)
  return {
    session = session,
    bufnr = session.bufnr,
    winid = vim.api.nvim_get_current_win(),
    revision = session.revision,
    token = next_search_token(session),
    direction = direction,
    count = count,
    kind = kind,
    valid = true,
  }
end

local function enter_search_cmdline(session, direction, count)
  if bridge and bridge.active then return end
  if bridge then M.invalidate_search(bridge.session) end
  clear_pending(session.input)
  motion.cancel(session)
  bridge = make_search_context(session, direction, count, session.cursor.area)
  vim.api.nvim_feedkeys(direction == 1 and '/' or '?', 'nit', false)
end

local function submit_search(context, text)
  local session = context.session
  if not context.valid or session.phase == 'closed' or not session.input
    or session.input.search_token ~= context.token
    or session.revision ~= context.revision
    or not vim.api.nvim_buf_is_valid(context.bufnr)
    or not vim.api.nvim_win_is_valid(context.winid)
    or vim.api.nvim_get_current_buf() ~= context.bufnr
    or vim.api.nvim_get_current_win() ~= context.winid
    or vim.api.nvim_win_get_buf(context.winid) ~= context.bufnr
    or require('hexit.session').get(context.bufnr) ~= session then
    return
  end
  if (session.phase ~= 'ready' and session.phase ~= 'saving') or not session.root then
    message('binary snapshot is not ready')
    return
  end

  if text == '' then
    if not session.search or not session.search.query then
      message('no previous search')
      return
    end
    search.start(session, session.search.query, context.direction, context.count)
    return
  end

  local query, err = search.parse(context.kind, text, session.options)
  if not query then
    message(err)
    return
  end
  search.start(session, query, context.direction, context.count)
end

local function cmdline_type(event)
  return event.cmdtype or vim.fn.getcmdtype()
end

local function cmdline_level(event)
  return tonumber(event.cmdlevel) or 0
end

local function activate_search_context(context, cmdtype, cmdlevel)
  context.active = true
  context.cmdtype, context.cmdlevel = cmdtype, cmdlevel
  search.suspend_navigation(context.session)
  motion.cancel(context.session)
  set_search_kind(context.session, context.kind)
  context.options = {
    incsearch = vim.o.incsearch,
    hlsearch = vim.o.hlsearch,
    hlsearch_state = vim.v.hlsearch,
  }
  vim.o.incsearch = false
  vim.o.hlsearch = false
  vim.cmd('nohlsearch')
end

local function on_cmdline_enter()
  local event = vim.v.event or {}
  local cmdtype = cmdline_type(event)
  if cmdtype ~= '/' and cmdtype ~= '?' then return end
  local cmdlevel = cmdline_level(event)
  if bridge and bridge.active then return end

  local session = current_session()
  if not session or session.phase == 'closed'
    or session.input.replace or session.mode == 'replace' then
    return
  end

  local context = bridge
  local direction = cmdtype == '/' and 1 or -1
  if context and context.session == session and context.direction == direction
    and context.valid and session.input.search_token == context.token then
    -- Consume the state prepared by our Plug/default mapping.
  else
    if context then M.invalidate_search(context.session) end
    clear_pending(session.input)
    context = make_search_context(session, direction, 1, session.cursor.area)
    bridge = context
  end
  activate_search_context(context, cmdtype, cmdlevel)
end

local function on_cmdline_leave()
  local event = vim.v.event or {}
  local cmdtype = cmdline_type(event)
  local cmdlevel = cmdline_level(event)
  local context = bridge
  if not context or not context.active or context.cmdtype ~= cmdtype
    or context.cmdlevel ~= cmdlevel then
    return
  end

  local text = vim.fn.getcmdline()
  local aborted = event.abort == true or event.abort == 1
  vim.cmd('let v:event.abort = v:true')
  bridge = nil
  restore_search_options(context)
  clear_search_kind(context.session)

  if aborted then
    if context.session.input and context.session.input.search_token == context.token then
      next_search_token(context.session)
    end
    return
  end

  vim.schedule(function() submit_search(context, text) end)
end

local function install_cmdline_handlers()
  if commandline_group then return end
  commandline_group = vim.api.nvim_create_augroup('HexitInputCmdline', { clear = true })
  vim.api.nvim_create_autocmd('CmdlineEnter', {
    group = commandline_group,
    pattern = { '/', '?' },
    callback = on_cmdline_enter,
  })
  vim.api.nvim_create_autocmd('CmdlineLeave', {
    group = commandline_group,
    pattern = { '/', '?' },
    callback = on_cmdline_leave,
  })
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
local function maparg_in_buffer(buf, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, 'n', false, true)
  end)
end

local function has_mapping(buf, lhs)
  local mapping = maparg_in_buffer(buf, lhs)
  return type(mapping) == 'table' and next(mapping) ~= nil
end
local function maps_to_hexit_plug(buf, lhs)
  local mapping = maparg_in_buffer(buf, lhs)
  return type(mapping) == 'table' and type(mapping.rhs) == 'string'
    and mapping.rhs:find('<Plug>(Hexit-', 1, true) ~= nil
end

local function clear_temporary(session)
  local state = session.input
  if not state or not state.temporary then return end
  local previous = state.temporary
  state.temporary = nil
  for _, key in ipairs(captured) do
    pcall(vim.keymap.del, 'n', canonical(key), { buffer = session.bufnr })
    local original = previous[key]
    if original and next(original) then
      pcall(vim.api.nvim_buf_call, session.bufnr, function()
        vim.fn.mapset('n', false, original)
      end)
    end
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
    local original = maparg_in_buffer(session.bufnr, lhs)
    if type(original) == 'table' and (original.buffer == 1 or original.buffer == true) then
      saved[key] = original
    end
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
  SearchForward = true, SearchBackward = true, SearchNext = true, SearchPrev = true,
}
for digit = 0, 9 do navigation['Digit' .. digit] = true end

local function dispatch(session, action, key)
  if action == 'Unsupported' then return end
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
  M.invalidate_search(session)
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
    if session.mode == 'visual' or session.mode == 'visual_line' then
      search.suspend_navigation(session)
    else
      search.cancel(session)
    end
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
    message('operation not supported yet')
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
    local toggling_out = action == 'Visual' and session.mode == 'visual'
      or action == 'VisualLine' and session.mode == 'visual_line'
    if toggling_out then search.suspend_navigation(session) end
    actions.visual(session, action == 'Visual' and 'visual' or 'visual_line')
  elseif action == 'Replace' or action == 'ReplaceMode' then
    if session.root.size == 0 then message('cannot replace an empty file'); return end
    if action == 'ReplaceMode' and (has_count or session.anchor) then
      message('counted or Visual R is not supported')
      return
    end
    search.suspend_navigation(session)
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
    if session.anchor then search.suspend_navigation(session) end
    local ok, err = actions.yank(session, count)
    if not ok then message(err) end
  elseif action == 'PasteAfter' or action == 'PasteBefore' then
    local ok, err = actions.paste(session, action == 'PasteAfter', count)
    if not ok then message(err) end
  elseif action == 'Undo' or action == 'Redo' then
    if session.anchor then search.suspend_navigation(session) end
    actions.history(session, action == 'Redo', count)
  elseif action == 'SearchForward' or action == 'SearchBackward' then
    enter_search_cmdline(session, action == 'SearchForward' and 1 or -1, count)
  elseif action == 'SearchNext' or action == 'SearchPrev' then

    if not session.search or not session.search.query then
      message('no previous search')
    else
      search.next(session, action == 'SearchNext' and session.search.direction
        or -session.search.direction, count)
    end
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
  session.input = { count = nil, prefix = nil, overflow = nil, search_token = 0 }
  install_cmdline_handlers()
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
      if not maps_to_hexit_plug(buf, key) then
        vim.keymap.set('n', key, '<Plug>(Hexit-' .. action .. ')',
          { buffer = buf, silent = true, nowait = true, remap = true })
      end
    end
    for digit = 0, 9 do
      local key = tostring(digit)
      if not maps_to_hexit_plug(buf, key) then
        vim.keymap.set('n', key, '<Plug>(Hexit-Digit' .. digit .. ')',
          { buffer = buf, silent = true, nowait = true, remap = true })
      end
    end
    for key, name in pairs(char_names) do
      local lhs = canonical(key)
      if not has_mapping(buf, lhs) then
        vim.keymap.set('n', lhs, name,
          { buffer = buf, silent = true, nowait = false, remap = true })
      end
    end
    for key, action in pairs(specials) do
      if not maps_to_hexit_plug(buf, key) then
        vim.keymap.set('n', key, '<Plug>(Hexit-' .. action .. ')',
          { buffer = buf, silent = true, nowait = true, remap = true })
      end
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
      M.invalidate_search(session)
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
