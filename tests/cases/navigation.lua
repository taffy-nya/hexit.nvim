local H = require('tests.helpers')
local sessions = require('hexit.session')
local layout = require('hexit.layout')

local function press(keys, predicate)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'xt', false)
  assert(vim.wait(1000, predicate, 10), 'input did not reach expected state: ' .. keys)
end

local function open(data)
  local path = H.temp_file(data)
  vim.cmd('Hex ' .. vim.fn.fnameescape(path))
  return H.wait_ready(vim.api.nvim_get_current_buf())
end

return {
  {
    name = 'NAV UI maps count nibble and area without native text edits',
    run = function()
      local session = open(H.bytes(0, 32, 65, 126, 127, 128, 255))
      local buf = session.bufnr
      press('4l', function() return session.cursor.offset == 2 and session.cursor.nibble == 0 end)
      H.eq(session.cursor.area, 'hex')
      press('<Tab>', function() return session.cursor.area == 'ascii' end)
      H.eq(session.cursor.offset, 2)
      press('<Tab>', function() return session.cursor.area == 'hex' end)
      H.eq(session.cursor.nibble, 0)
      local row = vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1]
      assert(row:find('00 20 41 7E 7F 80 FF', 1, true), row)
      assert(row:find('. A~...', 1, true), row)
      press('x', function() return true end)
      H.eq(session.root.size, 7)
      H.eq(vim.bo[buf].modifiable, false)
      H.eq(vim.bo[buf].modified, false)
      H.eq(vim.api.nvim_win_get_cursor(0)[2], layout.cell(session.layout, 2, 0, 'hex'))
    end,
  },
  {
    name = 'NAV overflow rejects entire counted motion and resets on Esc',
    run = function()
      local session = open('ABCD')
      local function keys(input)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input, true, false, true), 'xt', false)
      end
      keys('2147483648l')
      H.eq(session.cursor, { offset = 0, nibble = 0, area = 'hex' })
      press('l', function() return session.cursor.nibble == 1 end)
      keys('214748364899l')
      H.eq(session.cursor, { offset = 0, nibble = 1, area = 'hex' })
      keys('2147483648<Esc>')
      press('l', function() return session.cursor.offset == 1 end)
      keys('2147483648gg')
      H.eq(session.cursor.offset, 1)
      H.eq(session.input.prefix, nil)
    end,
  },
  {
    name = 'VIEW native Ctrl-e and Ctrl-y cannot scroll away the title',
    run = function()
      local session = open(string.rep('A', 2048))
      local cursor = vim.deepcopy(session.cursor)
      for _, key in ipairs({ '<C-e>', '<C-y>' }) do
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'xt', false)
        H.eq(vim.fn.winsaveview().topline, 1)
        H.eq(session.top_row, 0)
        H.eq(session.cursor, cursor)
      end
    end,
  },
  {
    name = 'NAV command-line entry discards pending g count and overflow',
    run = function()
      local session = open(string.rep('A', 64))
      local function keys(input)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input, true, false, true), 'xt', false)
      end
      keys('g:HexGoto 16<CR>l')
      H.eq(session.cursor, { offset = 16, nibble = 1, area = 'hex' })
      keys('24:HexGoto 0<CR>l')
      H.eq(session.cursor, { offset = 0, nibble = 1, area = 'hex' })
      keys('2147483648:HexGoto 16<CR>l')
      H.eq(session.cursor, { offset = 16, nibble = 1, area = 'hex' })
      keys('g:<Esc>l')
      H.eq(session.cursor, { offset = 17, nibble = 0, area = 'hex' })
    end,
  },
  {
    name = 'NAV commands preserve offset and reject bad locations',
    run = function()
      local session = open(string.rep('A', 34))
      vim.cmd('HexGoto 0x10')
      H.eq(session.cursor.offset, 16)
      vim.cmd('HexGoto 16')
      H.eq(session.cursor.offset, 16)
      vim.cmd('HexBytesPerRow 8')
      H.eq(session.bytes_per_row, 8)
      H.eq(session.cursor.offset, 16)
      for _, bad in ipairs({ 'HexGoto -1', 'HexGoto 1+2', 'HexGoto 34', 'HexGoto 0x', 'HexBytesPerRow 12' }) do
        H.eq(pcall(vim.cmd, bad), false)
        H.eq(session.cursor.offset, 16)
      end
      vim.cmd('HexBytesPerRow 32')
      H.eq(session.bytes_per_row, 32)
      H.eq(#vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false) <= session.height + 1, true)
    end,
  },
  {
    name = 'VIEW active nibble and partner cell are distinct extmarks',
    run = function()
      local session = open(H.bytes(0, 32, 65))
      local function highlights()
        local marks = vim.api.nvim_buf_get_extmarks(session.bufnr, require('hexit.view').namespace, 0, -1, { details = true })
        local result = {}
        for _, item in ipairs(marks) do
          if item[2] == 1 then result[item[4].hl_group] = item end
        end
        return result
      end
      local marks = highlights()
      assert(marks.HexCursor and marks.HexCursorMatch)
      H.eq(marks.HexCursor[3], layout.cell(session.layout, 0, 0, 'hex'))
      H.eq(marks.HexCursor[4].priority, 70)
      H.eq(marks.HexCursorMatch[3], layout.cell(session.layout, 0, 0, 'ascii'))
      press('l', function() return session.cursor.nibble == 1 end)
      marks = highlights()
      H.eq(marks.HexCursor[3], layout.cell(session.layout, 0, 1, 'hex'))
    end,
  },
  {
    name = 'VIEW split uses narrowest width and retains Byte cursor',
    run = function()
      require('hexit').setup({ bytes_per_row = 'auto' })
      local session = open(string.rep('B', 80))
      vim.cmd('HexGoto 53')
      H.eq(session.bytes_per_row, 16)
      press('l', function() return session.cursor.nibble == 1 end)
      local original = session.active_win
      vim.cmd('vsplit')
      require('hexit.view').render(session)
      local width = math.min(vim.api.nvim_win_get_width(original), vim.api.nvim_win_get_width(0))
      H.eq(session.layout.bpr, layout.compute(session.options, width, 80).bpr)
      H.eq(session.layout.bpr, 8)
      H.eq(session.cursor, { offset = 53, nibble = 1, area = 'hex' })
      vim.cmd('close')
      H.eq(sessions.get(session.bufnr), session)
      H.eq(session.bytes_per_row, 16)
      H.eq(session.cursor, { offset = 53, nibble = 1, area = 'hex' })
    end,
  },
  {
    name = 'VIEW short owner keeps EOF and page motions visible across tall split',
    run = function()
      local session = open(string.rep('AB', 1024))
      vim.cmd('split')
      vim.cmd('resize 5')
      local short = vim.api.nvim_get_current_win()
      local scrolloff = vim.api.nvim_get_option_value('scrolloff', { win = short })
      vim.api.nvim_set_option_value('scrolloff', 3, { win = short })
      local tall
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if win ~= short then tall = win end
      end
      assert(tall)
      vim.api.nvim_set_current_win(tall)
      vim.cmd('HexGoto 2047')
      H.eq(session.height, 15)
      H.eq(session.owner_height, 15)
      H.eq(session.top_row, 113)
      vim.api.nvim_set_current_win(short)
      H.eq(session.active_win, short)
      H.eq(session.owner_height, 4)
      H.eq(session.top_row, 124)
      H.eq(session.cursor.offset, 2047)
      H.eq(vim.api.nvim_win_get_cursor(short)[1], 5)
      H.eq(vim.fn.winsaveview().topline, 1)
      H.eq(#vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), 16)
      H.eq(vim.api.nvim_buf_get_lines(session.bufnr, 5, 6, false)[1], '')
      press('<C-u>', function() return session.cursor.offset == 2015 end)
      H.eq(session.top_row, 123)
      H.eq(vim.api.nvim_win_get_cursor(short)[1], 4)
      press('<C-d>', function() return session.cursor.offset == 2047 end)
      H.eq(session.top_row, 124)
      H.eq(vim.fn.winsaveview().topline, 1)
      vim.api.nvim_set_current_win(tall)
      H.eq(session.owner_height, 15)
      H.eq(session.top_row, 113)
      H.eq(vim.api.nvim_win_get_cursor(tall)[1], 16)
      H.eq(vim.fn.winsaveview().topline, 1)
      vim.api.nvim_set_option_value('scrolloff', scrolloff, { win = short })
      vim.cmd('close')
    end,
  },
  {
    name = 'NAV custom Plug key works without default input capture',
    run = function()
      require('hexit').setup({ mappings = false })
      local session = open('AB')
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(session.bufnr, 'n')) do
        assert(mapping.lhs ~= 'h', 'mappings=false installed a default key')
      end
      vim.keymap.set('n', '<F6>', '<Plug>(Hexit-SwitchArea)',
        { buffer = session.bufnr, remap = true })
      press('<F6>', function() return session.cursor.area == 'ascii' end)
      H.eq(session.cursor.offset, 0)
    end,
  },
  {
    name = 'VIEW hidden ASCII and offsets retain a navigable Hex display',
    run = function()
      require('hexit').setup({
        bytes_per_row = 8, show_ascii = false, show_offset = false, uppercase_hex = false,
      })
      local session = open(H.bytes(255, 10))
      local lines = vim.api.nvim_buf_get_lines(session.bufnr, 0, 2, false)
      H.eq(lines[1]:sub(1, 2), '00')
      assert(lines[2]:find('ff 0a', 1, true) == 1)
      H.eq(session.layout.hex_start, 0)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Tab>', true, false, true), 'xt', false)
      H.eq(session.cursor.area, 'hex')
      H.eq(session.cursor.offset, 0)
    end,
  },
  {
    name = 'VIEW hit testing and window option restoration',
    run = function()
      local wrap, number, scrolloff = vim.wo.wrap, vim.wo.number, vim.wo.scrolloff
      vim.wo.wrap, vim.wo.number, vim.wo.scrolloff = true, true, 3
      local session = open(H.bytes(0, 65, 255))
      local lay = session.layout
      H.eq(vim.wo.wrap, false)
      H.eq(vim.wo.number, false)
      H.eq(vim.wo.scrolloff, 0)
      vim.api.nvim_win_set_cursor(0, { 2, layout.cell(lay, 1, 1, 'hex') })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = session.bufnr })
      H.eq(session.cursor, { offset = 1, nibble = 1, area = 'hex' })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = session.bufnr })
      H.eq(session.cursor.offset, 1)
      vim.cmd('enew')
      assert(vim.wait(1000, function()
        return vim.wo.wrap and vim.wo.number and vim.wo.scrolloff == 3
      end, 10), 'Hex window options were not restored after leaving')
      vim.wo.wrap, vim.wo.number, vim.wo.scrolloff = false, false, 5
      vim.cmd('buffer ' .. session.bufnr)
      H.eq(vim.wo.scrolloff, 0)
      vim.cmd('enew')
      assert(vim.wait(1000, function()
        return not vim.wo.wrap and not vim.wo.number and vim.wo.scrolloff == 5
      end, 10), 're-entering Hex lost the latest window options')
      vim.wo.wrap, vim.wo.number, vim.wo.scrolloff = wrap, number, scrolloff
    end,
  },
  {
    name = 'VIEW leaving Hex preserves global scrolloff inheritance',
    run = function()
      local global = vim.api.nvim_get_option_value('scrolloff', { scope = 'global' })
      local local_value = vim.api.nvim_get_option_value('scrolloff', { scope = 'local', win = 0 })
      vim.api.nvim_set_option_value('scrolloff', 3, { scope = 'global' })
      vim.api.nvim_set_option_value('scrolloff', -1, { scope = 'local', win = 0 })
      open('AB')
      H.eq(vim.wo.scrolloff, 0)
      vim.cmd('enew')
      assert(vim.wait(1000, function()
        return vim.api.nvim_get_option_value('scrolloff', { scope = 'local', win = 0 }) == -1
      end, 10), 'leaving Hex converted inherited scrolloff to a local override')
      vim.api.nvim_set_option_value('scrolloff', 6, { scope = 'global' })
      H.eq(vim.wo.scrolloff, 6)
      vim.api.nvim_set_option_value('scrolloff', global, { scope = 'global' })
      vim.api.nvim_set_option_value('scrolloff', local_value, { scope = 'local', win = 0 })
    end,
  },
}
