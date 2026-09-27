local H = require('tests.helpers')
local layout = require('hexit.layout')
local view = require('hexit.view')
local motion = require('hexit.motion')
local api = require('hexit')

local function open(data)
  local path = H.temp_file(data)
  vim.cmd('Hex ' .. vim.fn.fnameescape(path))
  return H.wait_ready(vim.api.nvim_get_current_buf())
end

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

local function marked(session, group, row, col, finish)
  for _, item in ipairs(vim.api.nvim_buf_get_extmarks(session.bufnr, view.namespace, 0, -1, { details = true })) do
    if item[2] == row and item[3] == col and item[4].end_col == finish
      and item[4].hl_group == group then return true end
  end
  return false
end
local function virtual_marks(session, group)
  local found, text, count = nil, nil, 0
  for _, item in ipairs(vim.api.nvim_buf_get_extmarks(session.bufnr, view.namespace, 0, -1, { details = true })) do
    local details = item[4]
    for _, chunk in ipairs(details.virt_text or {}) do
      if chunk[2] == group then
        found, count = item, count + 1
        text = (text or '') .. chunk[1]
      end
    end
  end
  return found, text, count
end

local function title_text(session, group)
  local mark, text = virtual_marks(session, group)
  assert(mark, 'missing title mark ' .. group)
  return mark, text
end

local function completed_search(session)
  assert(vim.wait(10000, function()
    return session.search and not session.search.pending and session.search.total ~= nil
  end, 10), 'search scan did not finish')
end

local function option(win, name)
  return vim.api.nvim_get_option_value(name, { win = win, scope = 'local' })
end

local function assert_window_options(win, statusline, winbar, global_statusline, global_winbar, laststatus)
  H.eq(option(win, 'statusline'), statusline)
  H.eq(option(win, 'winbar'), winbar)
  H.eq(vim.api.nvim_get_option_value('statusline', { scope = 'global' }), global_statusline)
  H.eq(vim.api.nvim_get_option_value('winbar', { scope = 'global' }), global_winbar)
  H.eq(vim.o.laststatus, laststatus)
end

local function header_ruler_marks(session)
  local result = {}
  for _, item in ipairs(vim.api.nvim_buf_get_extmarks(session.bufnr, view.namespace, 0, -1, { details = true })) do
    local details = item[4]
    if item[2] == 0 and details.end_col and details.end_col > item[3]
      and type(details.hl_group) == 'string' and details.hl_group:find('^HexHeader') then
      result[#result + 1] = item
    end
  end
  return result
end

local function assert_hex_only_header(session)
  local lay = session.layout
  local heading = vim.api.nvim_buf_get_lines(session.bufnr, 0, 1, false)[1]
  H.eq(#heading, lay.width)
  for col = 0, lay.bpr - 1 do
    local hex = layout.cell(lay, col, 0, 'hex')
    H.eq(heading:sub(hex + 1, hex + 2), (lay.uppercase_hex and '%02X' or '%02x'):format(col))
    if lay.show_ascii then
      local ascii = layout.cell(lay, col, 0, 'ascii')
      H.eq(heading:sub(ascii + 1, ascii + 1), ' ')
    end
  end
  for _, item in ipairs(header_ruler_marks(session)) do
    local col, finish = item[3], item[4].end_col
    local is_hex_cell = false
    for byte_col = 0, lay.bpr - 1 do
      local hex = layout.cell(lay, byte_col, 0, 'hex')
      if col == hex and finish == hex + 2 then is_hex_cell = true; break end
    end
    assert(is_hex_cell, ('header ruler mark is not a hex cell: %s..%s'):format(col, finish))
  end
end

return {
  { name = 'UX status snapshot reflects Byte, selection and pure title projection', run = function()
    H.eq(api.get_status(), nil)
    local s = open(string.rep('a', 17))
    local status = require('hexit.status')
    local first = api.get_status(s.bufnr)
    H.eq(first.position_text, '0x00000000')
    H.eq(first.nibble, 'high')
    local before = vim.deepcopy(first)
    H.eq(status.header(first), { mode = 'NORMAL', right = 'HEX  0x00000000' })
    H.eq(first, before)
    first.offset = 999
    H.eq(api.get_status(s.bufnr).offset, 0)
    keys('lv')
    local selected = api.get_status(s.bufnr)
    H.eq(selected.nibble, 'low')
    H.eq(selected.mode_text, 'VISUAL')
    H.eq(selected.selection.length, 1)
    H.eq(selected.range_text, '0x00000000–0x00000000 (1 B)')
    H.eq(status.header(selected), { mode = 'VISUAL', right = '1B  HEX  0x00000000' })
    keys('<Esc>')
    H.eq(api.get_status(s.bufnr).selection, nil)
    H.eq(api.get_status(987654321), nil)
  end },
  { name = 'UX status handles loading, empty and wide Byte offsets', run = function()
    local status = require('hexit.status')
    local empty = open('')
    H.eq(api.get_status(empty.bufnr).offset, nil)
    H.eq(api.get_status(empty.bufnr).position_text, '(empty)')
    H.eq(status.header(api.get_status(empty.bufnr)), { mode = 'NORMAL', right = 'HEX  (empty)' })
    local synthetic = {
      bufnr = empty.bufnr, phase = 'loading', options = { uppercase_hex = false },
      cursor = { offset = 0, nibble = 0, area = 'hex' }, mode = 'normal',
    }
    H.eq(status.project(synthetic).position_text, '--')
    synthetic.phase = 'ready'
    synthetic.root = { size = 0x100000002 }
    synthetic.cursor.offset = 0x100000000
    H.eq(status.project(synthetic).position_text, '0x100000000')
    H.eq(status.header(status.project(synthetic)), { mode = 'NORMAL', right = 'HEX  0x100000000' })
    synthetic.options.uppercase_hex = true
    synthetic.mode, synthetic.anchor = 'visual', 0x100000000
    synthetic.cursor.offset = 0x100000001
    synthetic.bytes_per_row = 16
    local snapshot = status.project(synthetic)
    H.eq(snapshot.range_text, '0x100000000–0x100000001 (2 B)')
    H.eq(status.header(snapshot), { mode = 'VISUAL', right = '2B  HEX  0x100000001' })
  end },
  { name = 'UX status events follow logical changes while title reads stay passive', run = function()
    local events = 0
    local group = vim.api.nvim_create_augroup('HexitUXStatusTest', { clear = true })
    vim.api.nvim_create_autocmd('User', { group = group, pattern = 'HexitStatusChanged',
      callback = function() events = events + 1 end })
    local ok, err = xpcall(function()
      local s = open('ABCD')
      vim.wait(40, function() return false end, 10)
      local baseline = events
      keys('v')
      assert(vim.wait(1000, function() return events > baseline end, 10))
      local snapshot = api.get_status(s.bufnr)
      H.eq(snapshot.mode_text, 'VISUAL')
      H.eq(require('hexit.status').header(snapshot).mode, 'VISUAL')
      local consumed = events
      api.get_status(s.bufnr)
      require('hexit.status').header(api.get_status(s.bufnr))
      vim.wait(40, function() return false end, 10)
      H.eq(events, consumed)
    end, debug.traceback)
    vim.api.nvim_del_augroup_by_id(group)
    if not ok then error(err) end
  end },
  { name = 'UX title extmarks project mode, search and area without moving the cursor', run = function()
    local status = require('hexit.status')
    local s = open('XAXA')
    local function check(mode, fragment)
      local before = vim.api.nvim_win_get_cursor(0)
      local snapshot = api.get_status(s.bufnr)
      local title = status.header(snapshot)
      H.eq(title.mode, mode)
      if fragment then assert(title.right:find(fragment, 1, true), title.right) end
      view.render(s)
      H.eq(vim.api.nvim_win_get_cursor(0), before)

      local mode_mark, mode_text, mode_count = virtual_marks(s, 'HexHeaderMode')
      local right_mark, right_text, right_count = virtual_marks(s, 'HexHeaderStatus')
      H.eq(mode_count, 1)
      H.eq(right_count, 1)
      H.eq(mode_text, title.mode)
      H.eq(right_text, title.right)
      H.eq(mode_mark[2], 0)
      H.eq(mode_mark[3], 0)
      H.eq(mode_mark[4].virt_text_win_col, 0)
      H.eq(mode_mark[4].priority, 80)
      H.eq(mode_mark[4].hl_mode, 'replace')
      H.eq(right_mark[2], 0)
      H.eq(right_mark[3], 0)
      H.eq(right_mark[4].virt_text_pos, 'right_align')
      H.eq(right_mark[4].priority, 100)
      H.eq(right_mark[4].hl_mode, 'replace')
      return snapshot, title
    end

    local snapshot, title = check('NORMAL', 'HEX  0x00000000')
    H.eq(snapshot.offset, 0)
    H.eq(title.right, 'HEX  0x00000000')
    vim.cmd('HexSearch hex 41')
    completed_search(s)
    snapshot, title = check('NORMAL', '1/2')
    H.eq(title.right, '1/2  HEX  0x00000001')
    keys('v')
    snapshot, title = check('VISUAL', '1B')
    H.eq(snapshot.selection.length, 1)
    H.eq(title.right, '1B  1/2  HEX  0x00000001')
    keys('V')
    check('V-LINE', 'B')
    keys('<Esc>R')
    check('REPLACE', 'HEX')
    keys('<Esc><Tab>')
    check('NORMAL', 'ASCII')
    keys('<Esc>')
  end },
  { name = 'UX title rendering preserves modified state independently', run = function()
    local s = open('AB')
    H.eq(vim.bo[s.bufnr].modified, false)
    keys('rF')
    H.eq(vim.bo[s.bufnr].modified, true)
    title_text(s, 'HexHeaderStatus')
    view.render(s)
    H.eq(vim.bo[s.bufnr].modified, true)
    keys('u')
    H.eq(vim.bo[s.bufnr].modified, false)
    view.render(s)
    H.eq(vim.bo[s.bufnr].modified, false)
    title_text(s, 'HexHeaderStatus')
  end },
  { name = 'UX hex-only ruler and Visual marks follow actual selected columns', run = function()
    local s = open(string.rep('a', 16) .. 'xy')
    local lay = s.layout
    assert_hex_only_header(s)
    assert(marked(s, 'HexHeader', 0, layout.cell(lay, 0, 0, 'hex'), layout.cell(lay, 0, 0, 'hex') + 2))
    assert(marked(s, 'HexHeaderCurrent', 0, layout.cell(lay, 0, 0, 'hex'), layout.cell(lay, 0, 0, 'hex') + 2))
    assert(marked(s, 'HexOffsetCurrent', 1, 0, lay.offset_width))
    vim.cmd('HexGoto 16')
    keys('V')
    H.eq(api.get_status(s.bufnr).selection.length, 2)
    assert(marked(s, 'HexHeaderSelection', 0, layout.cell(lay, 0, 0, 'hex'), layout.cell(lay, 0, 0, 'hex') + 2))
    assert(marked(s, 'HexHeaderSelection', 0, layout.cell(lay, 1, 0, 'hex'), layout.cell(lay, 1, 0, 'hex') + 2))
    assert(not marked(s, 'HexHeaderSelection', 0, layout.cell(lay, 2, 0, 'hex'), layout.cell(lay, 2, 0, 'hex') + 2))
    assert(not marked(s, 'HexCursor', 2, layout.cell(lay, 0, 0, 'hex'), layout.cell(lay, 0, 0, 'hex') + 1))
    assert(marked(s, 'HexOffsetSelection', 2, 0, lay.offset_width))
    assert_hex_only_header(s)
  end },
  { name = 'UX logical scrolloff preserves margin and physical title', run = function()
    H.eq(motion.visible_top(10, 10, 100, 9, 2), 8)
    H.eq(motion.visible_top(10, 18, 100, 9, 2), 12)
    H.eq(motion.visible_top(10, 99, 100, 9, 2), 91)
    H.eq(motion.visible_top(10, 10, 100, 3, 9), 9)
    local win = vim.api.nvim_get_current_win()
    vim.cmd('setlocal scrolloff=3')
    local s = open(string.rep('x', 3200))
    H.eq(vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' }), 0)
    H.eq(s.scrolloff, 3)
    vim.cmd('HexGoto 160')
    H.eq(s.top_row, 0)
    vim.cmd('HexGoto 320')
    assert(s.top_row > 0)
    H.eq(vim.fn.winsaveview().topline, 1)
    vim.cmd('setlocal scrolloff=5')
    view.render(s)
    H.eq(s.scrolloff, 5)
    vim.cmd('enew')
    H.eq(vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' }), 5)
    vim.api.nvim_set_option_value('scrolloff', -1, { win = win, scope = 'local' })
  end },
  { name = 'UX inherited logical scrolloff follows global changes without losing local inheritance', run = function()
    local win = vim.api.nvim_get_current_win()
    local original_local = vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' })
    local original_global = vim.api.nvim_get_option_value('scrolloff', { scope = 'global' })
    local s
    local ok, err = xpcall(function()
      vim.cmd('setglobal scrolloff=3')
      vim.api.nvim_set_option_value('scrolloff', -1, { win = win, scope = 'local' })
      s = open(string.rep('x', 1024))
      H.eq(s.scrolloff, 3)
      H.eq(vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' }), 0)
      vim.cmd('setglobal scrolloff=9')
      view.render(s)
      H.eq(s.scrolloff, 9)
      H.eq(vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' }), 0)
      vim.cmd('enew')
      H.eq(vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' }), -1)
      vim.cmd('setglobal scrolloff=4')
      vim.api.nvim_set_current_buf(s.bufnr)
      H.eq(s.scrolloff, 4)
      vim.cmd('setlocal scrolloff=5')
      view.render(s)
      H.eq(s.scrolloff, 5)
      vim.cmd('setglobal scrolloff=11')
      view.render(s)
      H.eq(s.scrolloff, 5)
      H.eq(vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' }), 0)
      vim.cmd('setlocal scrolloff<')
      view.render(s)
      H.eq(s.scrolloff, 11)
      vim.cmd('setglobal scrolloff=12')
      view.render(s)
      H.eq(s.scrolloff, 11)
      vim.cmd('setlocal scrolloff=-1')
      view.render(s)
      H.eq(s.scrolloff, 12)
      vim.cmd('enew')
      H.eq(vim.api.nvim_get_option_value('scrolloff', { win = win, scope = 'local' }), -1)
    end, debug.traceback)
    if s and vim.api.nvim_get_current_buf() == s.bufnr then pcall(vim.cmd, 'enew!') end
    vim.api.nvim_set_option_value('scrolloff', original_local, { win = win, scope = 'local' })
    vim.api.nvim_set_option_value('scrolloff', original_global, { scope = 'global' })
    if not ok then error(err) end
  end },
  { name = 'UX empty and one-byte titles keep position fields and hex-only headers', run = function()
    local empty = open('')
    assert_hex_only_header(empty)
    H.eq(select(2, title_text(empty, 'HexHeaderStatus')), 'HEX  (empty)')
    local short = open('A')
    assert_hex_only_header(short)
    H.eq(select(2, title_text(short, 'HexHeaderStatus')), 'HEX  0x00000000')
    H.eq(short.root.size, 1)
  end },
  { name = 'UX ruler aligns row, group and display-option combinations', run = function()
    local s = open(string.rep('A', 33))
    for _, bpr in ipairs({ 8, 16, 32 }) do
      for _, group in ipairs({ 1, 2, 4 }) do
        for _, upper in ipairs({ true, false }) do
          for _, show_ascii in ipairs({ true, false }) do
            for _, show_offset in ipairs({ true, false }) do
              s.options.bytes_per_row = bpr
              s.options.byte_group_size = group
              s.options.uppercase_hex = upper
              s.options.show_ascii = show_ascii
              s.options.show_offset = show_offset
              view.render(s)
              assert_hex_only_header(s)
            end
          end
        end
      end
    end
  end },
  { name = 'UX real colorscheme change rebuilds Byte defaults and preserves later overrides', run = function()
    local original_ascii = vim.api.nvim_get_hl(0, { name = 'HexAscii' })
    local original_match = vim.api.nvim_get_hl(0, { name = 'HexCursorMatch' })
    local ok, err = xpcall(function()
      local s = open('AB')
      local lay = s.layout
      assert(marked(s, 'HexAscii', 1, layout.cell(lay, 0, 0, 'ascii'),
        layout.cell(lay, 0, 0, 'ascii') + 1))
      assert(marked(s, 'HexCursorMatch', 1, layout.cell(lay, 0, 0, 'ascii'),
        layout.cell(lay, 0, 0, 'ascii') + 1))
      H.eq(vim.api.nvim_get_hl(0, { name = 'HexOffset' }).link, 'LineNr')
      H.eq(vim.api.nvim_get_hl(0, { name = 'HexHeader' }).link, 'LineNr')
      H.eq(vim.api.nvim_get_hl(0, { name = 'HexHeaderCurrent' }).link, 'CursorLineNr')
      H.eq(vim.api.nvim_get_hl(0, { name = 'HexAscii' }).link, 'Normal')
      H.eq(vim.api.nvim_get_hl(0, { name = 'HexCursorMatch' }).link, 'Visual')
      vim.cmd.colorscheme('default')
      H.eq(vim.api.nvim_get_hl(0, { name = 'HexAscii' }).link, 'Normal')
      H.eq(vim.api.nvim_get_hl(0, { name = 'HexCursorMatch' }).link, 'Visual')
      vim.api.nvim_set_hl(0, 'HexAscii', { fg = 0x123456 })
      vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'default' })
      H.eq(vim.api.nvim_get_hl(0, { name = 'HexAscii' }).fg, 0x123456)
      keys('v')
      assert(marked(s, 'HexSelection', 1, layout.cell(lay, 0, 0, 'ascii'),
        layout.cell(lay, 0, 0, 'ascii') + 1))
      assert(not marked(s, 'HexCursorMatch', 1, layout.cell(lay, 0, 0, 'ascii'),
        layout.cell(lay, 0, 0, 'ascii') + 1))
    end, debug.traceback)
    vim.api.nvim_set_hl(0, 'HexAscii', original_ascii)
    vim.api.nvim_set_hl(0, 'HexCursorMatch', original_match)
    if not ok then error(err) end
  end },
  { name = 'UX title lifecycle never changes window statusline, winbar or laststatus', run = function()
    local first_win = vim.api.nvim_get_current_win()
    local original_global_statusline = vim.api.nvim_get_option_value('statusline', { scope = 'global' })
    local original_global_winbar = vim.api.nvim_get_option_value('winbar', { scope = 'global' })
    local original_local_statusline, original_local_winbar = option(first_win, 'statusline'), option(first_win, 'winbar')
    local original_laststatus = vim.o.laststatus
    local second_win
    local ok, err = xpcall(function()
      local a = open('A')
      assert_window_options(first_win, original_local_statusline, original_local_winbar,
        original_global_statusline, original_global_winbar, original_laststatus)

      local global_statusline, global_winbar, laststatus = 'GlobalHexStatus', 'GlobalHexWinbar', 0
      vim.api.nvim_set_option_value('statusline', global_statusline, { scope = 'global' })
      vim.api.nvim_set_option_value('winbar', global_winbar, { scope = 'global' })
      vim.api.nvim_set_option_value('statusline', '', { win = first_win, scope = 'local' })
      vim.api.nvim_set_option_value('winbar', '', { win = first_win, scope = 'local' })
      vim.api.nvim_set_option_value('laststatus', laststatus, { scope = 'global' })
      assert_window_options(first_win, '', '', global_statusline, global_winbar, laststatus)
      view.render(a)
      assert_window_options(first_win, '', '', global_statusline, global_winbar, laststatus)

      local b = open('B')
      H.eq(a.bufnr == b.bufnr, false)
      assert_window_options(first_win, '', '', global_statusline, global_winbar, laststatus)
      vim.api.nvim_set_option_value('statusline', 'LocalHexStatus', { win = first_win, scope = 'local' })
      vim.api.nvim_set_option_value('winbar', 'LocalHexWinbar', { win = first_win, scope = 'local' })
      view.render(b)
      assert_window_options(first_win, 'LocalHexStatus', 'LocalHexWinbar',
        global_statusline, global_winbar, laststatus)

      vim.cmd('vsplit')
      second_win = vim.api.nvim_get_current_win()
      assert_window_options(second_win, 'LocalHexStatus', 'LocalHexWinbar',
        global_statusline, global_winbar, laststatus)
      vim.api.nvim_set_option_value('statusline', '', { win = second_win, scope = 'local' })
      vim.api.nvim_set_option_value('winbar', '', { win = second_win, scope = 'local' })
      local c = open('C')
      H.eq(vim.api.nvim_win_get_buf(first_win), b.bufnr)
      H.eq(vim.api.nvim_win_get_buf(second_win), c.bufnr)
      assert_window_options(first_win, 'LocalHexStatus', 'LocalHexWinbar',
        global_statusline, global_winbar, laststatus)
      assert_window_options(second_win, '', '', global_statusline, global_winbar, laststatus)
      H.eq(select(2, title_text(b, 'HexHeaderStatus')), 'HEX  0x00000000')
      H.eq(select(2, title_text(c, 'HexHeaderStatus')), 'HEX  0x00000000')

      for _, value in ipairs({ 0, 1, 2, 3 }) do
        vim.api.nvim_set_option_value('laststatus', value, { scope = 'global' })
        view.render(b)
        view.render(c)
        assert_window_options(first_win, 'LocalHexStatus', 'LocalHexWinbar',
          global_statusline, global_winbar, value)
        assert_window_options(second_win, '', '', global_statusline, global_winbar, value)
      end
    end, debug.traceback)
    if second_win and vim.api.nvim_win_is_valid(second_win) then
      pcall(vim.api.nvim_win_close, second_win, true)
    end
    if vim.api.nvim_win_is_valid(first_win) then
      vim.api.nvim_set_current_win(first_win)
      pcall(vim.cmd, 'enew!')
      vim.api.nvim_set_option_value('statusline', original_local_statusline,
        { win = first_win, scope = 'local' })
      vim.api.nvim_set_option_value('winbar', original_local_winbar,
        { win = first_win, scope = 'local' })
    end
    vim.api.nvim_set_option_value('statusline', original_global_statusline, { scope = 'global' })
    vim.api.nvim_set_option_value('winbar', original_global_winbar, { scope = 'global' })
    vim.api.nvim_set_option_value('laststatus', original_laststatus, { scope = 'global' })
    if not ok then error(err) end
  end },
}
