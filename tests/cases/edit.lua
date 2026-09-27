local H = require('tests.helpers')
local doc = require('hexit.document')
local view = require('hexit.view')
local layout = require('hexit.layout')

local function open(data)
  local path = H.temp_file(data)
  vim.cmd('Hex ' .. vim.fn.fnameescape(path))
  return H.wait_ready(vim.api.nvim_get_current_buf()), path
end
local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end
local function value(session)
  return doc.read(session.root, 0, session.root.size)
end

return {
  {
    name = 'EDIT nibble and ASCII replacement preserve exact bytes and undo positions',
    run = function()
      local s = open(H.bytes(0xAB, 0xCD))
      keys('rF')
      H.eq(value(s), H.bytes(0xFB, 0xCD))
      H.eq(s.cursor, { offset = 0, nibble = 0, area = 'hex' })
      keys('lu')
      H.eq(value(s), H.bytes(0xAB, 0xCD))
      H.eq(s.cursor.nibble, 0)
      keys('lrF')
      H.eq(value(s), H.bytes(0xAF, 0xCD))
      keys('u<C-r>')
      H.eq(value(s), H.bytes(0xAF, 0xCD))
      keys('<Tab>r ')
      H.eq(value(s), H.bytes(0x20, 0xCD))
      H.eq(vim.bo[s.bufnr].modifiable, false)
    end,
  },
  {
    name = 'EDIT counted low nibble spans bytes and rejects EOF atomically',
    run = function()
      local s = open(H.bytes(0xAB, 0xCD))
      keys('l2rF')
      H.eq(value(s), H.bytes(0xAF, 0xFD))
      H.eq(s.cursor, { offset = 1, nibble = 0, area = 'hex' })
      H.eq(#s.undo, 1)
      keys('u')
      H.eq(value(s), H.bytes(0xAB, 0xCD))
      keys('l4rF')
      H.eq(value(s), H.bytes(0xAB, 0xCD))
      H.eq(#s.redo, 1)
    end,
  },
  {
    name = 'EDIT Replace Mode groups live writes into one undo and stops at EOF',
    run = function()
      local s = open(H.bytes(0x12, 0x34, 0x56, 0x78))
      keys('RDEADBEEF')
      H.eq(value(s), H.bytes(0xDE, 0xAD, 0xBE, 0xEF))
      H.eq(s.eof_after_replace, true)
      keys('0')
      H.eq(value(s), H.bytes(0xDE, 0xAD, 0xBE, 0xEF))
      keys('<Esc>u')
      H.eq(value(s), H.bytes(0x12, 0x34, 0x56, 0x78))
      keys('<C-r>')
      H.eq(value(s), H.bytes(0xDE, 0xAD, 0xBE, 0xEF))
      H.eq(#s.undo, 1)
    end,
  },
  {
    name = 'EDIT Replace ignores page and wheel navigation and restores Plug Escape',
    run = function()
      local original = string.rep('A', 1024)
      local s = open(original)
      vim.keymap.set('n', '<F6>', '<Plug>(Hexit-PageDown)', { buffer = s.bufnr, remap = true })
      vim.keymap.set('n', '<F7>', '<Plug>(Hexit-Escape)', { buffer = s.bufnr, remap = true })
      keys('RDE')
      H.eq(s.cursor.offset, 1)
      keys('<C-f>')
      H.eq(s.cursor.offset, 1)
      keys('<ScrollWheelDown>')
      H.eq(s.cursor.offset, 1)
      H.eq(s.top_row, 0)
      keys('<C-b><ScrollWheelUp><C-e><C-y><F6>')
      H.eq(s.cursor.offset, 1)
      keys('AD<F7>')
      H.eq(s.mode, 'normal')
      H.eq(value(s), H.bytes(0xDE, 0xAD) .. string.rep('A', 1022))
      H.eq(#s.undo, 1)
      keys('u')
      H.eq(value(s), original)
      keys('r<C-f>')
      H.eq(s.cursor.offset, 0)
      H.eq(value(s), original)
    end,
  },
  {
    name = 'EDIT Replace blocks CursorMoved hit until Esc and restores normal hit testing',
    run = function()
      local original = string.rep('A', 1024)
      local s = open(original)
      keys('RDE')
      H.eq(s.cursor.offset, 1)
      local replacement_cursor = vim.api.nvim_win_get_cursor(0)
      local clicked = { 4, layout.cell(s.layout, 0, 0, 'hex') }
      vim.api.nvim_win_set_cursor(0, clicked)
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.bufnr })
      H.eq(s.cursor.offset, 1)
      H.eq(vim.api.nvim_win_get_cursor(0), replacement_cursor)
      keys('AD<Esc>')
      H.eq(value(s), H.bytes(0xDE, 0xAD) .. string.rep('A', 1022))
      H.eq(#s.undo, 1)
      vim.api.nvim_win_set_cursor(0, clicked)
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = s.bufnr })
      H.eq(s.cursor.offset, 32)
      keys('u')
      H.eq(value(s), original)
    end,
  },
  {
    name = 'EDIT ASCII Replace Mode writes spaces and digits but not UTF-8 bytes',
    run = function()
      local s = open('abcd')
      keys('<Tab>R 2')
      H.eq(value(s), ' 2cd')
      keys('é')
      H.eq(value(s), ' 2cd')
      keys('<Esc>')
      H.eq(#s.undo, 1)
      keys('u')
      H.eq(value(s), 'abcd')
    end,
  },
  {
    name = 'SELECT complete byte ranges, linewise short tail and reversible Fill',
    run = function()
      local s = open(H.bytes(1, 2, 3, 4, 5, 6, 7, 8, 9))
      keys('lv')
      H.eq({ require('hexit.actions').selection(s) }, { 0, 1 })
      keys('ll')
      H.eq({ require('hexit.actions').selection(s) }, { 0, 2 })
      local marks = vim.api.nvim_buf_get_extmarks(s.bufnr, view.namespace, 0, -1, { details = true })
      local selected, active, partner = 0, false, false
      for _, mark in ipairs(marks) do
        if mark[4].hl_group == 'HexSelection' then
          H.eq(mark[4].priority, 50)
          selected = selected + 1
        elseif mark[4].hl_group == 'HexCursor' then
          active = mark[4].priority == 70
        elseif mark[4].hl_group == 'HexCursorMatch' then
          partner = mark[4].priority == 60
        end
      end
      H.eq(selected, 4)
      H.eq(active, false)
      H.eq(partner, true)
      keys('rFF')
      H.eq(value(s), H.bytes(255, 255, 3, 4, 5, 6, 7, 8, 9))
      local dirty = 0
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.bufnr, view.namespace, 0, -1, { details = true })) do
        if mark[4].hl_group == 'HexModified' then
          H.eq(mark[4].priority, 20)
          dirty = dirty + 1
        end
      end
      H.eq(dirty, 4)
      H.eq(s.mode, 'normal')
      keys('uVj')
      H.eq({ require('hexit.actions').selection(s) }, { 0, 9 })
      keys('<Esc>')
      H.eq(value(s), H.bytes(1, 2, 3, 4, 5, 6, 7, 8, 9))
    end,
  },
  {
    name = 'EDIT logical Visual and Replace state stays visible in title',
    run = function()
      local original = string.rep('A', 1024)
      local s = open(original)
      local function title_text(group)
        local text, count = '', 0
        for _, item in ipairs(vim.api.nvim_buf_get_extmarks(s.bufnr, view.namespace, 0, -1, { details = true })) do
          for _, chunk in ipairs(item[4].virt_text or {}) do
            if chunk[2] == group then
              text, count = text .. chunk[1], count + 1
            end
          end
        end
        H.eq(count, 1)
        return text
      end
      local function check_title(mode)
        local expected = require('hexit.status').header(require('hexit').get_status(s.bufnr))
        H.eq(expected.mode, mode)
        local cursor = vim.api.nvim_win_get_cursor(0)
        view.render(s)
        H.eq(vim.api.nvim_win_get_cursor(0), cursor)
        H.eq(title_text('HexHeaderMode'), expected.mode)
        H.eq(title_text('HexHeaderStatus'), expected.right .. ' ')
        return expected
      end

      keys('VG')
      H.eq({ require('hexit.actions').selection(s) }, { 0, 1024 })
      local visual = check_title('V-LINE')
      assert(visual.right:find('1024B', 1, true), visual.right)
      keys('<Esc>ggR')
      local hex_replace = check_title('REPLACE')
      H.eq(hex_replace.right, 'HEX  0x00000000')
      keys('<Esc><Tab>R')
      local ascii_replace = check_title('REPLACE')
      H.eq(ascii_replace.right, 'ASCII  0x00000000')
      keys('<Esc>')
      H.eq(value(s), original)
    end,
  },
  {
    name = 'EDIT binary yank and counted insertion are whole-byte and one transaction',
    run = function()
      local s = open(H.bytes(0, 255, 65))
      keys('ly2p')
      H.eq(value(s), H.bytes(0, 0, 0, 255, 65))
      H.eq(s.cursor.offset, 1)
      keys('u')
      H.eq(value(s), H.bytes(0, 255, 65))
      keys('vly')
      H.eq(require('hexit.actions').register().size, 2)
      keys('P')
      H.eq(value(s), H.bytes(0, 255, 0, 255, 65))
      H.eq(#s.undo, 1)
    end,
  },
  {
    name = 'HISTORY clean dirty and saved snapshot compare content',
    run = function()
      local s = open(H.bytes(1, 2))
      keys('rF')
      H.eq(vim.bo[s.bufnr].modified, true)
      keys('u')
      H.eq(vim.bo[s.bufnr].modified, false)
      keys('<C-r>')
      H.eq(vim.bo[s.bufnr].modified, true)
      keys('r0')
      assert(vim.wait(1000, function() return not vim.bo[s.bufnr].modified end, 10))
    end,
  },
  {
    name = 'EDIT 1MiB Visual fill and undo preserve a single history entry',
    run = function()
      local s = open(string.rep(H.bytes(0), 1024 * 1024))
      keys('v')
      vim.cmd('HexGoto 1048575')
      H.eq({ require('hexit.actions').selection(s) }, { 0, 1024 * 1024 })
      keys('rFF')
      H.eq(s.root.size, 1024 * 1024)
      H.eq(doc.read(s.root, 0, 3), H.bytes(255, 255, 255))
      H.eq(doc.read(s.root, s.root.size - 3, 3), H.bytes(255, 255, 255))
      H.eq(#s.undo, 1)
      keys('u')
      H.eq(s.root, s.saved_root)
      H.eq(vim.bo[s.bufnr].modified, false)
    end,
  },
  {
    name = 'EDIT invalid and incomplete replacement never destroys redo or changes bytes',
    run = function()
      local s = open(H.bytes(0xAB, 0xCD))
      keys('rF')
      keys('u')
      H.eq(#s.redo, 1)
      keys('5rF')
      H.eq(value(s), H.bytes(0xAB, 0xCD))
      keys('rZ')
      H.eq(value(s), H.bytes(0xAB, 0xCD))
      keys('vrF<Esc>')
      H.eq(value(s), H.bytes(0xAB, 0xCD))
      H.eq(#s.redo, 1)
      keys('<C-r>')
      H.eq(value(s), H.bytes(0xFB, 0xCD))
      keys('xid')
      H.eq(value(s), H.bytes(0xFB, 0xCD))
    end,
  },
  {
    name = 'EDIT empty document P and private register survives session close',
    run = function()
      local first = open(H.bytes(0xAB, 0xCD))
      keys('2y')
      H.eq(require('hexit.actions').register().size, 2)
      vim.api.nvim_buf_delete(first.bufnr, { force = true })
      local second = open('')
      keys('3P')
      H.eq(value(second), H.bytes(0xAB, 0xCD, 0xAB, 0xCD, 0xAB, 0xCD))
      H.eq(second.cursor.offset, 0)
      keys('u')
      H.eq(value(second), '')
      H.eq(#second.undo, 0)
    end,
  },
  {
    name = 'HISTORY saving retains undo and redo returns exactly to saved content',
    run = function()
      local s, path = open(H.bytes(1, 2))
      keys('rF')
      vim.cmd('write')
      H.eq(H.read_disk(path), H.bytes(0xF1, 2))
      H.eq(vim.bo[s.bufnr].modified, false)
      keys('u')
      H.eq(vim.bo[s.bufnr].modified, true)
      keys('<C-r>')
      assert(vim.wait(1000, function() return not vim.bo[s.bufnr].modified end, 10))
      H.eq(value(s), H.read_disk(path))
    end,
  },
  {
    name = 'EDIT custom Plug Replace Mode captures and restores printable maps',
    run = function()
      require('hexit').setup({ mappings = false })
      local s = open(H.bytes(0, 0))
      local buf = s.bufnr
      vim.keymap.set('n', 'q', '<Plug>(Hexit-ReplaceMode)', { buffer = buf, remap = true })
      vim.keymap.set('n', 'z', '<Plug>(Hexit-SwitchArea)', { buffer = buf, remap = true })
      keys('qAz<Esc>')
      H.eq(value(s), H.bytes(0xA0, 0))
      H.eq(s.cursor.area, 'hex')
      keys('z')
      H.eq(s.cursor.area, 'ascii')
      keys('z')
      H.eq(s.cursor.area, 'hex')
      keys('qAA<Esc>')
      H.eq(value(s), H.bytes(0xAA, 0))
    end,
  },
  {
    name = 'EDIT switching buffers cancels pending r and commits live R history',
    run = function()
      local s = open(H.bytes(0, 1))
      keys('r')
      local other = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_set_current_buf(other)
      vim.api.nvim_set_current_buf(s.bufnr)
      keys('F')
      H.eq(value(s), H.bytes(0, 1))
      keys('RAB')
      H.eq(value(s), H.bytes(0xAB, 1))
      vim.api.nvim_set_current_buf(other)
      H.eq(s.mode, 'normal')
      H.eq(#s.undo, 1)
      vim.api.nvim_set_current_buf(s.bufnr)
      keys('u')
      H.eq(value(s), H.bytes(0, 1))
    end,
  },
  {
    name = 'EDIT counted Byte paste uses bounded pieces and remains one undo',
    run = function()
      local s = open(H.bytes(0xAB))
      keys('y131072p')
      H.eq(s.root.size, 131073)
      H.eq(doc.read(s.root, 0, 3), H.bytes(0xAB, 0xAB, 0xAB))
      H.eq(doc.read(s.root, 131070, 3), H.bytes(0xAB, 0xAB, 0xAB))
      assert(#s.root.pieces <= 4, 'counted single-Byte paste allocated a piece for each repeat')
      H.eq(#s.undo, 1)
      keys('u')
      H.eq(value(s), H.bytes(0xAB))
    end,
  },
  {
    name = 'EDIT long R coalesces pieces while updating visible Bytes immediately',
    run = function()
      local original = string.rep('A', 2050)
      local s = open(original)
      keys('<Tab>RBC')
      H.eq(doc.read(s.root, 0, 3), 'BCA')
      local row = vim.api.nvim_buf_get_lines(s.bufnr, 1, 2, false)[1]
      assert(row:find('42 43 41', 1, true), row)
      keys(string.rep('D', 2046) .. '<Esc>')
      H.eq(doc.read(s.root, 0, 2050), 'BC' .. string.rep('D', 2046) .. 'AA')
      assert(#s.root.pieces <= 4, 'Replace Mode kept one piece per Byte')
      H.eq(#s.undo, 1)
      keys('u')
      H.eq(value(s), original)
    end,
  },
  {
    name = 'EDIT Hex R and pending r hand colon back to native command line',
    run = function()
      local s = open(H.bytes(0, 1, 2))
      keys('RDE:HexGoto 2<CR>')
      H.eq(value(s), H.bytes(0xDE, 1, 2))
      H.eq(s.mode, 'normal')
      H.eq(s.cursor.offset, 2)
      H.eq(#s.undo, 1)
      keys('u')
      H.eq(value(s), H.bytes(0, 1, 2))
      keys('r:HexGoto 1<CR>')
      H.eq(value(s), H.bytes(0, 1, 2))
      H.eq(s.cursor.offset, 1)
      keys('l')
      H.eq(s.cursor.nibble, 1)
    end,
  },
  {
    name = 'EDIT ASCII r and R keep colon as literal printable Byte',
    run = function()
      local s = open('ab')
      keys('<Tab>R:<Esc>')
      H.eq(value(s), ':b')
      H.eq(s.mode, 'normal')
      keys('r:')
      H.eq(value(s), '::')
      H.eq(#s.undo, 2)
      keys('2u')
      H.eq(value(s), 'ab')
    end,
  },
}
