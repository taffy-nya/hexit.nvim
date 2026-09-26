local layout = require('hexit.layout')
local document = require('hexit.document')
local search = require('hexit.search')

local M = {}
local ns = vim.api.nvim_create_namespace('HexitView')
M.namespace = ns
local window_options = { 'wrap', 'number', 'relativenumber', 'foldcolumn', 'signcolumn', 'conceallevel', 'scrolloff' }
local window_values = { wrap = false, number = false, relativenumber = false, foldcolumn = '0', signcolumn = 'no', conceallevel = 0, scrolloff = 0 }
local saved_windows, preceding_windows, tracked_buffers = {}, {}, {}
local rendering = false

local function windows(session)
  local result = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == session.bufnr then
      result[#result + 1] = win
    end
  end
  return result
end

local function snapshot_window(win)
  local saved = {}
  for _, option in ipairs(window_options) do
    local opts = { win = win }
    if option == 'scrolloff' then opts.scope = 'local' end
    saved[option] = vim.api.nvim_get_option_value(option, opts)
  end
  return saved
end

local transitions = vim.api.nvim_create_augroup('HexitWindowTransitions', { clear = true })
vim.api.nvim_create_autocmd('BufLeave', {
  group = transitions,
  callback = function(args)
    if not next(tracked_buffers) or tracked_buffers[args.buf] then return end
    local win = vim.api.nvim_get_current_win()
    if not saved_windows[win] then preceding_windows[win] = snapshot_window(win) end
  end,
})

vim.api.nvim_create_autocmd('WinClosed', {
  group = vim.api.nvim_create_augroup('HexitWindowCleanup', { clear = true }),
  callback = function(args)
    local win = tonumber(args.match)
    saved_windows[win], preceding_windows[win] = nil, nil
  end,
})

local function set_window(win)
  if not saved_windows[win] then
    saved_windows[win] = preceding_windows[win] or snapshot_window(win)
    preceding_windows[win] = nil
  end
  for option, value in pairs(window_values) do
    vim.api.nvim_set_option_value(option, value, { win = win })
  end
end

local function restore_window(win)
  local saved = saved_windows[win]
  if not saved then return end
  saved_windows[win] = nil
  if not vim.api.nvim_win_is_valid(win) then return end
  for option, value in pairs(saved) do
    vim.api.nvim_set_option_value(option, value, { win = win })
  end
end
vim.api.nvim_create_autocmd('BufEnter', {
  group = transitions,
  callback = function(args)
    if not tracked_buffers[args.buf] then restore_window(vim.api.nvim_get_current_win()) end
  end,
})

local function restore_after_leave(win, buf)
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then
      saved_windows[win] = nil
    elseif vim.api.nvim_win_get_buf(win) ~= buf and not tracked_buffers[vim.api.nvim_win_get_buf(win)] then
      restore_window(win)
    end
  end)
end

local function keep_title_visible()
  if vim.fn.line('w0') ~= 1 then vim.fn.winrestview({ topline = 1 }) end
end

local function heading(lay, session, width)
  local chars = {}
  local selected = 0
  if session.anchor ~= nil and session.root then
    local start, stop = require('hexit.actions').selection(session)
    selected = stop - start
  end
  local mode = session.mode == 'replace' and ('REPLACE ' .. session.cursor.area:upper())
    or ((session.mode == 'visual' or session.mode == 'visual_line')
      and ('VISUAL (' .. selected .. ' B)') or 'NORMAL')
  local prefix = session.cursor.area == 'hex'
    and ('%s H%d'):format(mode, session.cursor.nibble) or (mode .. ' A')
  if session.search and session.search.query then
    local result = session.search
    local ordinal = result.ordinal or (result.total == 0 and 0 or '?')
    local total = result.total or '?'
    prefix = prefix .. ('  %s/%s%s  '):format(ordinal, total, result.pending and ' searching…' or '')
  end
  for col = 0, lay.bpr - 1 do
    local byte = (lay.uppercase_hex and '%02X' or '%02x'):format(col)
    local screen = layout.cell(lay, col, 0, 'hex')
    chars[screen + 1], chars[screen + 2] = byte:sub(1, 1), byte:sub(2, 2)
    if lay.show_ascii then
      chars[layout.cell(lay, col, 0, 'ascii') + 1] =
        (lay.uppercase_hex and '%X' or '%x'):format(col % 16)
    end
  end
  -- Status takes priority over the first column numbers in a narrow viewport;
  -- it must not disappear past the right edge of the fixed-width data grid.
  for i = 1, math.min(#prefix, width) do chars[i] = prefix:sub(i, i) end
  local limit = math.max(lay.width, math.min(#prefix, width))
  for i = 1, limit do if chars[i] == nil then chars[i] = ' ' end end
  local area = session.cursor.area:upper()
  local nibble = session.cursor.area == 'hex' and (session.cursor.nibble == 0 and ' HI' or ' LO') or ''
  local status = ('  %s %s%s  %d B/row'):format(mode, area, nibble, lay.bpr)
  return table.concat(chars, '', 1, limit) .. status
end

local function mark(buf, line, start_col, end_col, group, priority)
  vim.api.nvim_buf_set_extmark(buf, ns, line, start_col, {
    end_row = line, end_col = end_col, hl_group = group, priority = priority,
  })
end

local function marks(session, lay, height)
  local buf = session.bufnr
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if session.phase ~= 'ready' and session.phase ~= 'saving' then return end
  local size = session.root.size
  local selection_start, selection_stop
  if session.anchor ~= nil then
    selection_start = math.min(session.anchor, session.cursor.offset)
    selection_stop = math.max(session.anchor, session.cursor.offset) + 1
    if session.mode == 'visual_line' then
      selection_start = math.floor(selection_start / lay.bpr) * lay.bpr
      selection_stop = math.min(size, math.ceil(selection_stop / lay.bpr) * lay.bpr)
    end
  end
  local matches = search.visible_matches(session, session.top_row * lay.bpr,
    math.min(size, (session.top_row + height) * lay.bpr))
  local match_index = 1
  for screen_row = 0, height - 1 do
    local offset = (session.top_row + screen_row) * lay.bpr
    local count = math.min(lay.bpr, size - offset)
    if count > 0 then
      local row = screen_row + 1
      if lay.show_offset then mark(buf, row, 0, lay.offset_width, 'HexOffset', 10) end
      local dirty = document.dirty_runs(session.root, session.saved_root, offset, count)
      local dirty_idx = 1
      for col = 0, count - 1 do
        local byte = offset + col
        local hex = layout.cell(lay, col, 0, 'hex')
        mark(buf, row, hex, hex + 2, 'HexByte', 10)
        local ascii = lay.show_ascii and layout.cell(lay, col, 0, 'ascii')
        if ascii then mark(buf, row, ascii, ascii + 1, 'HexAscii', 10) end
        while dirty[dirty_idx] and byte >= dirty[dirty_idx][2] do dirty_idx = dirty_idx + 1 end
        while matches[match_index] and byte >= matches[match_index].stop do
          match_index = match_index + 1
        end
        local match = matches[match_index]
        if match and byte >= match.start then
          local group = match.current and 'HexSearchCurrent' or 'HexSearch'
          local priority = match.current and 40 or 30
          mark(buf, row, hex, hex + 2, group, priority)
          if ascii then mark(buf, row, ascii, ascii + 1, group, priority) end
        end
        if dirty[dirty_idx] and byte >= dirty[dirty_idx][1] then
          mark(buf, row, hex, hex + 2, 'HexModified', 20)
          if ascii then mark(buf, row, ascii, ascii + 1, 'HexModified', 20) end
        end
        if selection_start and byte >= selection_start and byte < selection_stop then
          mark(buf, row, hex, hex + 2, 'HexSelection', 50)
          if ascii then mark(buf, row, ascii, ascii + 1, 'HexSelection', 50) end
        end
        if byte == session.cursor.offset then
          if session.cursor.area == 'hex' then
            mark(buf, row, hex + session.cursor.nibble, hex + session.cursor.nibble + 1, 'HexCursor', 70)
            if ascii then mark(buf, row, ascii, ascii + 1, 'HexCursorMatch', 60) end
          else
            mark(buf, row, ascii, ascii + 1, 'HexCursor', 70)
            mark(buf, row, hex, hex + 2, 'HexCursorMatch', 60)
          end
        end
      end
    end
  end
end

function M.render(session)
  if rendering or session.phase == 'closed' or not vim.api.nvim_buf_is_valid(session.bufnr) then return end
  rendering = true
  local ok, err = xpcall(function()
    local visible = windows(session)
    local width, height = math.huge, 1
    for _, win in ipairs(visible) do
      set_window(win)
      width = math.min(width, vim.api.nvim_win_get_width(win))
      height = math.max(height, vim.api.nvim_win_get_height(win) - 1)
    end
    if width == math.huge then width = vim.o.columns end
    local owner = session.active_win
    if not owner or not vim.api.nvim_win_is_valid(owner) or vim.api.nvim_win_get_buf(owner) ~= session.bufnr then
      owner = visible[1]
    end
    session.active_win = owner
    local owner_height = owner and math.max(1, vim.api.nvim_win_get_height(owner) - 1) or height
    local size = session.root and session.root.size or 0
    local lay = layout.compute(session.options, width, size)
    session.layout = lay
    session.bytes_per_row = lay.bpr
    session.height = height
    session.owner_height = owner_height
    if (session.phase == 'ready' or session.phase == 'saving') and size > 0 then
      local rows = math.ceil(size / lay.bpr)
      session.top_row = math.max(0, math.min(session.top_row, math.max(0, rows - owner_height)))
      local row = math.floor(session.cursor.offset / lay.bpr)
      if row < session.top_row then session.top_row = row end
      if row >= session.top_row + owner_height then session.top_row = row - owner_height + 1 end
    else
      session.top_row = 0
    end
    local lines = {}
    if session.phase == 'ready' or session.phase == 'saving' then
      lines[1] = heading(lay, session, width)
      for i = 0, height - 1 do
        lines[#lines + 1] = layout.row(session.root, session.top_row + i, lay)
      end
    else
      local label = session.phase == 'error' and ('Hexit [error] ' .. session.error)
        or ('Hexit [loading] %d/%s bytes: %s'):format(session.loaded_bytes, session.total_bytes or '?', session.path)
      lines[1] = label
    end
    local buf = session.bufnr
    local modified = vim.bo[buf].modified
    vim.bo[buf].modifiable = true
    local changed, change_err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = modified
    if not changed then error(change_err) end
    marks(session, lay, height)
    if (session.phase == 'ready' or session.phase == 'saving') and size > 0 then
      local col = session.cursor.offset % lay.bpr
      local line = math.floor(session.cursor.offset / lay.bpr) - session.top_row + 2
      local screen = layout.cell(lay, col, session.cursor.nibble, session.cursor.area)
      for _, win in ipairs(visible) do
        if line <= vim.api.nvim_win_get_height(win) then
          vim.api.nvim_win_set_cursor(win, { line, screen })
          vim.api.nvim_win_call(win, keep_title_visible)
        end
      end
    end
  end, debug.traceback)
  rendering = false
  if not ok then error(err) end
end

function M.scroll(session, rows)
  if (session.phase ~= 'ready' and session.phase ~= 'saving') or session.root.size == 0 then return end
  local max_row = math.max(0, math.ceil(session.root.size / session.bytes_per_row) - session.owner_height)
  session.top_row = math.max(0, math.min(max_row, session.top_row + rows))
  local row = math.floor(session.cursor.offset / session.bytes_per_row)
  if row < session.top_row then
    session.cursor.offset = math.min(session.root.size - 1, session.top_row * session.bytes_per_row + session.cursor.offset % session.bytes_per_row)
  elseif row >= session.top_row + session.owner_height then
    session.cursor.offset = math.min(session.root.size - 1, (session.top_row + session.owner_height - 1) * session.bytes_per_row + session.cursor.offset % session.bytes_per_row)
  end
  M.render(session)
end

function M.attach(session)
  local buf = session.bufnr
  tracked_buffers[buf] = true
  local function active()
    return session.phase ~= 'closed' and vim.api.nvim_get_current_buf() == buf
  end
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'WinResized', 'VimResized' }, {
    group = session.augroup,
    callback = function()
      if active() then
        session.active_win = vim.api.nvim_get_current_win()
        M.render(session)
      elseif session.phase ~= 'closed' then
        M.render(session)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufLeave', {
    group = session.augroup, buffer = buf,
    callback = function() restore_after_leave(vim.api.nvim_get_current_win(), buf) end,
  })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = session.augroup, buffer = buf,
    callback = function()
      if rendering or (session.phase ~= 'ready' and session.phase ~= 'saving')
        or session.root.size == 0 then return end
      if session.input and session.input.replace then
        M.render(session)
        return
      end
      local win = vim.api.nvim_get_current_win()
      local pos = vim.api.nvim_win_get_cursor(win)
      local cursor = layout.hit(session.layout, pos[1], pos[2], session.top_row, session.root.size)
      if cursor then
        session.cursor = cursor
        session.preferred_col = nil
      end
      M.render(session)
    end,
  })
  session.on_change = M.render
  M.render(session)
end

function M.detach(session)
  tracked_buffers[session.bufnr] = nil
  for _, win in ipairs(windows(session)) do
    restore_after_leave(win, session.bufnr)
  end
end

return M
