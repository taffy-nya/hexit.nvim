local H = require('tests.helpers')
local document = require('hexit.document')
local view = require('hexit.view')
local layout = require('hexit.layout')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

local function open(data)
  local path = H.temp_file(data)
  vim.cmd('Hex ' .. vim.fn.fnameescape(path))
  return H.wait_ready(vim.api.nvim_get_current_buf()), path
end

local function completed(s)
  assert(vim.wait(10000, function()
    return s.search and not s.search.pending and s.search.total ~= nil
  end, 10), 'search scan did not finish')
end

local function has_mark(s, group, line, start, stop, priority)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.bufnr, view.namespace, { line, start }, { line, stop }, { details = true })) do
    local details = mark[4]
    if details.hl_group == group and mark[2] == line and mark[3] == start
      and details.end_col == stop and details.priority == priority then return true end
  end
  return false
end

return {
  {
    name = 'SEARCH UI command and prompt navigate literal matches and show both areas',
    run = function()
      local s = open('a.a* a.a*')
      vim.cmd('HexSearch ascii a.')
      completed(s)
      H.eq(s.search.total, 2)
      H.eq(s.cursor.offset, 5)
      H.eq(s.search.ordinal, 2)
      H.eq(require('hexit').get_status(s.bufnr).search_text, '2/2')
      local hex = layout.cell(s.layout, 5, 0, 'hex')
      local ascii = layout.cell(s.layout, 5, 0, 'ascii')
      assert(has_mark(s, 'HexSearchCurrent', 1, hex, hex + 2, 40))
      assert(has_mark(s, 'HexSearchCurrent', 1, ascii, ascii + 1, 40))
      keys('n')
      completed(s)
      H.eq(s.cursor.offset, 0)
      H.eq(s.search.ordinal, 1)
      H.eq(s.search.direction, 1)
      keys('N')
      completed(s)
      H.eq(s.cursor.offset, 5)
      H.eq(s.search.direction, 1)
      local prior = vim.ui.input
      vim.ui.input = function() error('search must use native command line') end
      local ok, err = xpcall(function()
        keys('/2A<CR>')
        assert(vim.wait(10000, function()
          return s.search and s.search.query.kind == 'hex' and s.search.query.bytes == '*'
            and s.search.total == 2 and not s.search.pending and s.cursor.offset == 8
        end, 10), 'native Hex search did not finish')
      end, debug.traceback)
      vim.ui.input = prior
      if not ok then error(err) end
      keys('rF')
      completed(s)
      H.eq(document.read(s.root, 8, 1), H.bytes(0xFA))
      H.eq(s.search.total, 1)
      keys('u')
      completed(s)
      H.eq(s.search.total, 2)
    end,
  },
  {
    name = 'SEARCH UI rejects malformed command without losing current search',
    run = function()
      local s = open(H.bytes(0, 255, 0, 255))
      vim.cmd('HexSearch hex 00 FF')
      completed(s)
      H.eq(s.search.total, 2)
      H.eq(pcall(vim.cmd, 'HexSearch hex ??'), false)
      H.eq(pcall(vim.cmd, 'HexSearch text .'), false)
      H.eq(s.search.total, 2)
      keys('?<Esc>')
      H.eq(s.search.query.kind, 'hex')
    end,
  },
  {
    name = 'SEARCH VIEW clips cross-row matches and layers Visual and cursor',
    run = function()
      local s = open(string.rep('.', 15) .. 'ABCD' .. string.rep('.', 12) .. 'ABCD')
      vim.cmd('HexSearch ascii ABCD')
      completed(s)
      H.eq(s.search.total, 2)
      H.eq(s.cursor.offset, 15)
      local h15 = layout.cell(s.layout, 15, 0, 'hex')
      local a15 = layout.cell(s.layout, 15, 0, 'ascii')
      local h0 = layout.cell(s.layout, 0, 0, 'hex')
      local a0 = layout.cell(s.layout, 0, 0, 'ascii')
      assert(has_mark(s, 'HexSearchCurrent', 1, h15, h15 + 2, 40))
      assert(has_mark(s, 'HexSearchCurrent', 1, a15, a15 + 1, 40))
      assert(has_mark(s, 'HexSearchCurrent', 2, h0, h0 + 2, 40))
      assert(has_mark(s, 'HexSearchCurrent', 2, a0, a0 + 1, 40))
      assert(has_mark(s, 'HexSearch', 2, h15, h15 + 2, 30))
      assert(has_mark(s, 'HexSearch', 2, a15, a15 + 1, 30))
      keys('vll')
      H.eq(s.cursor.offset, 16)
      assert(has_mark(s, 'HexSelection', 1, h15, h15 + 2, 50))
      assert(has_mark(s, 'HexCursorMatch', 2, a0, a0 + 1, 60))
      assert(not has_mark(s, 'HexCursor', 2, h0, h0 + 1, 70))
    end,
  },
  {
    name = 'SEARCH command preserves significant ASCII spaces',
    run = function()
      local s = open('A A ')
      vim.cmd('HexSearch ascii  A')
      completed(s)
      H.eq(s.search.total, 1)
      H.eq(s.cursor.offset, 1)
      vim.cmd('HexSearch ascii A ')
      completed(s)
      H.eq(s.search.total, 2)
      H.eq(s.cursor.offset, 2)
    end,
  },
  {
    name = 'SEARCH paste uses final inserted-byte cursor for current ordinal',
    run = function()
      local s = open('aa')
      vim.cmd('HexSearch ascii a')
      completed(s)
      vim.cmd('HexGoto 0')
      keys('yp')
      completed(s)
      H.eq(document.read(s.root, 0, s.root.size), 'aaa')
      H.eq(s.cursor.offset, 1)
      H.eq(s.search.current, 1)
      H.eq(s.search.ordinal, 2)
      H.eq(s.search.total, 3)
    end,
  },
  {
    name = 'SEARCH Visual Fill uses selection-start cursor for current ordinal',
    run = function()
      local s = open('aaxa')
      vim.cmd('HexSearch ascii a')
      completed(s)
      H.eq(s.cursor.offset, 1)
      keys('vllr61')
      completed(s)
      H.eq(document.read(s.root, 0, s.root.size), 'aaaa')
      H.eq(s.cursor.offset, 1)
      H.eq(s.search.current, 1)
      H.eq(s.search.ordinal, 2)
      H.eq(s.search.total, 4)
    end,
  },
  {
    name = 'SEARCH Escape hides matches without losing the last query',
    run = function()
      local s = open(string.rep('x', 512) .. 'a')
      vim.cmd('HexSearch ascii a')
      completed(s)
      keys('<Esc>')
      H.eq(s.search.total, 1)
      H.eq(require('hexit').get_status(s.bufnr).search_text, '')
      vim.cmd('HexGoto 512')
      local row = math.floor(512 / s.layout.bpr) - s.top_row + 1
      local hex = layout.cell(s.layout, 512 % s.layout.bpr, 0, 'hex')
      local ascii = layout.cell(s.layout, 512 % s.layout.bpr, 0, 'ascii')
      assert(not has_mark(s, 'HexSearchCurrent', row, hex, hex + 2, 40))
      assert(not has_mark(s, 'HexSearchCurrent', row, ascii, ascii + 1, 40))
      keys('n')
      assert(vim.wait(2000, function()
        return has_mark(s, 'HexSearchCurrent', row, hex, hex + 2, 40)
          and has_mark(s, 'HexSearchCurrent', row, ascii, ascii + 1, 40)
      end, 10), 'explicit n did not resume hidden search')
    end,
  },
}
