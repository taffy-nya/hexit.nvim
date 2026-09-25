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
      assert(lines[1]:find('NORMAL H0', 1, true) == 1)
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
      local wrap, number = vim.wo.wrap, vim.wo.number
      vim.wo.wrap, vim.wo.number = true, true
      local session = open(H.bytes(0, 65, 255))
      local lay = session.layout
      H.eq(vim.wo.wrap, false)
      H.eq(vim.wo.number, false)
      vim.api.nvim_win_set_cursor(0, { 2, layout.cell(lay, 1, 1, 'hex') })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = session.bufnr })
      H.eq(session.cursor, { offset = 1, nibble = 1, area = 'hex' })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = session.bufnr })
      H.eq(session.cursor.offset, 1)
      vim.cmd('enew')
      H.eq(vim.wo.wrap, true)
      H.eq(vim.wo.number, true)
      vim.wo.wrap, vim.wo.number = wrap, number
    end,
  },
}
