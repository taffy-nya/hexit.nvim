local layout = require('hexit.layout')
local document = require('hexit.document')
local search = require('hexit.search')
local motion = require('hexit.motion')
local status = require('hexit.status')

local M = {}
local ns = vim.api.nvim_create_namespace('HexitView')
M.namespace = ns
local window_options = { 'wrap', 'number', 'relativenumber', 'foldcolumn', 'signcolumn', 'conceallevel', 'scrolloff' }
local window_values = { wrap = false, number = false, relativenumber = false, foldcolumn = '0', signcolumn = 'no', conceallevel = 0, scrolloff = 0 }
local saved_windows, preceding_windows, tracked_buffers = {}, {}, {}
local rendering, setting_options = false, false
local function set_local(win, option, value)
  setting_options = true
  local ok, err = pcall(vim.api.nvim_set_option_value, option, value, { win = win, scope = 'local' })
  setting_options = false
  if not ok then error(err) end
end

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
vim.api.nvim_create_autocmd('OptionSet', {
  group = transitions, pattern = 'scrolloff',
  callback = function()
    if setting_options or vim.v.option_type ~= 'local' then return end
    local win = vim.api.nvim_get_current_win()
    local saved = saved_windows[win]
    if not saved then return end
    saved.scrolloff = vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' })
    set_local(win, 'scrolloff', 0)
  end,
})

local function set_window(win)
  if not saved_windows[win] then
    saved_windows[win] = preceding_windows[win] or snapshot_window(win)
    preceding_windows[win] = nil
  end
  for option, value in pairs(window_values) do
    if option == 'scrolloff' then set_local(win, option, value)
    else vim.api.nvim_set_option_value(option, value, { win = win }) end
  end
end

local function restore_window(win)
  local saved = saved_windows[win]
  if not saved then return end
  saved_windows[win] = nil
  if not vim.api.nvim_win_is_valid(win) then return end
  for option, value in pairs(saved) do
    if option == 'scrolloff' then set_local(win, option, value)
    else vim.api.nvim_set_option_value(option, value, { win = win }) end
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
local function logical_scrolloff(win)
  local saved = win and saved_windows[win]
  local local_value = saved and saved.scrolloff or -1
  return local_value >= 0 and local_value or vim.api.nvim_get_option_value('scrolloff', { scope = 'global' })
end

local function keep_title_visible()
  if vim.fn.line('w0') ~= 1 then vim.fn.winrestview({ topline = 1 }) end
end

local function heading(lay)
  local chars = {}
  for col = 0, lay.bpr - 1 do
    local byte = (lay.uppercase_hex and '%02X' or '%02x'):format(col)
    local screen = layout.cell(lay, col, 0, 'hex')
    chars[screen + 1], chars[screen + 2] = byte:sub(1, 1), byte:sub(2, 2)
  end
  for i = 1, lay.width do if chars[i] == nil then chars[i] = ' ' end end
  return table.concat(chars, '', 1, lay.width)
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
  local selection_start, selection_stop = require('hexit.actions').selection(session)
  local visual = session.mode == 'visual' or session.mode == 'visual_line'
  local selected_columns = {}
  if selection_start then
    if selection_stop - selection_start >= lay.bpr then
      for col = 0, lay.bpr - 1 do selected_columns[col] = true end
    else
      for byte = selection_start, selection_stop - 1 do selected_columns[byte % lay.bpr] = true end
    end
  end
  for col = 0, lay.bpr - 1 do
    local hex = layout.cell(lay, col, 0, 'hex')
    local selected = selection_start and selected_columns[col]
    if not selected then mark(buf, 0, hex, hex + 2, 'HexHeader', 10) end
    local group = selected and 'HexHeaderSelection'
      or not visual and size > 0 and session.cursor.offset % lay.bpr == col and 'HexHeaderCurrent'
    if group then mark(buf, 0, hex, hex + 2, group, selected and 50 or 60) end
  end
  local title = status.header(status.project(session))
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { title.mode, 'HexHeaderMode' } }, virt_text_win_col = 1,
    hl_mode = 'replace', priority = 80,
  })
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
    virt_text = { { title.right .. ' ', 'HexHeaderStatus' } }, virt_text_pos = 'right_align',
    hl_mode = 'replace', priority = 100,
  })
  local matches = search.visible_matches(session, session.top_row * lay.bpr,
    math.min(size, (session.top_row + height) * lay.bpr))
  local match_index = 1
  for screen_row = 0, height - 1 do
    local offset = (session.top_row + screen_row) * lay.bpr
    local count = math.min(lay.bpr, size - offset)
    if count > 0 then
      local row = screen_row + 1
      if lay.show_offset then
        local offset_start = lay.hex_start - lay.offset_width - 2
        local selected = selection_start and offset < selection_stop and offset + count > selection_start
        if not selected then mark(buf, row, offset_start, offset_start + lay.offset_width, 'HexOffset', 10) end
        if selected then
          mark(buf, row, offset_start, offset_start + lay.offset_width, 'HexOffsetSelection', 50)
        elseif not visual and session.cursor.offset >= offset and session.cursor.offset < offset + count then
          mark(buf, row, offset_start, offset_start + lay.offset_width, 'HexOffsetCurrent', 60)
        end
      end
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
            if not visual then
              mark(buf, row, hex + session.cursor.nibble, hex + session.cursor.nibble + 1, 'HexCursor', 70)
            end
            if ascii then mark(buf, row, ascii, ascii + 1, 'HexCursorMatch', 60) end
          else
            if not visual then mark(buf, row, ascii, ascii + 1, 'HexCursor', 70) end
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
    session.scrolloff = logical_scrolloff(owner)
    local size = session.root and session.root.size or 0
    local lay = layout.compute(session.options, width, size)
    session.layout = lay
    session.bytes_per_row = lay.bpr
    session.height = height
    session.owner_height = owner_height
    if (session.phase == 'ready' or session.phase == 'saving') and size > 0 then
      session.top_row = motion.visible_top(session.top_row, math.floor(session.cursor.offset / lay.bpr),
        math.ceil(size / lay.bpr), owner_height, session.scrolloff)
    else
      session.top_row = 0
    end
    local lines = {}
    if session.phase == 'ready' or session.phase == 'saving' then
      lines[1] = heading(lay)
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
  status.changed(session)
end

function M.scroll(session, rows)
  if (session.phase ~= 'ready' and session.phase ~= 'saving') or session.root.size == 0 then return end
  local bpr, height = session.bytes_per_row, session.owner_height
  local total = math.ceil(session.root.size / bpr)
  local max_top = math.max(0, total - height)
  local top = math.max(0, math.min(max_top, session.top_row + rows))
  local margin = math.min(math.max(0, session.scrolloff or 0), math.floor((height - 1) / 2))
  local low = top == 0 and 0 or top + margin
  local high = top == max_top and total - 1 or top + height - 1 - margin
  local row = math.max(low, math.min(high, math.floor(session.cursor.offset / bpr)))
  session.top_row = top
  session.cursor.offset = math.min(session.root.size - 1, row * bpr + session.cursor.offset % bpr)
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
