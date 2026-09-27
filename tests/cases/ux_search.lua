local H = require('tests.helpers')
local api = require('hexit')
local view = require('hexit.view')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

local function open(data)
  local path = H.temp_file(data)
  vim.cmd('Hex ' .. vim.fn.fnameescape(path))
  return H.wait_ready(vim.api.nvim_get_current_buf())
end

local function settled(s, offset, total)
  assert(vim.wait(10000, function()
    return s.search and s.search.total == total and not s.search.pending and s.cursor.offset == offset
  end, 10), ('search did not settle: offset=%d total=%s'):format(s.cursor.offset, s.search and s.search.total))
end

return {
  { name = 'UX native search preserves regex register, options, and ASCII query direction', run = function()
    local saved = { incsearch = vim.o.incsearch, hlsearch = vim.o.hlsearch, pattern = vim.fn.getreg('/'),
      highlight = vim.v.hlsearch }
    local ok, err = xpcall(function()
      vim.o.incsearch, vim.o.hlsearch = true, true
      vim.fn.setreg('/', 'sentinel-pattern')
      local s = open('xAxAxA')
      keys('<Tab>')
      H.eq(s.cursor.area, 'ascii')
      local prior = vim.ui.input
      vim.ui.input = function() error('vim.ui.input is not a native search') end
      local searched, problem = xpcall(function()
        keys('/A<CR>')
        settled(s, 1, 3)
      end, debug.traceback)
      vim.ui.input = prior
      if not searched then error(problem) end
      H.eq(vim.fn.getreg('/'), 'sentinel-pattern')
      H.eq(vim.o.incsearch, true)
      H.eq(vim.o.hlsearch, true)
      H.eq(s.search.query.kind, 'ascii')
      keys('3n')
      settled(s, 1, 3)
      H.eq(s.search.wrapped, true)
      keys('?<CR>')
      settled(s, 5, 3)
      H.eq(s.search.direction, -1)
      H.eq(vim.fn.getreg('/'), 'sentinel-pattern')
    end, debug.traceback)
    vim.o.incsearch, vim.o.hlsearch = saved.incsearch, saved.hlsearch
    vim.fn.setreg('/', saved.pattern)
    if saved.highlight == 0 then vim.cmd.nohlsearch() end
    if not ok then error(err) end
  end },
  { name = 'UX counted navigation wrap uses original count and Esc hides marks', run = function()
    local s = open('xAxAxA')
    vim.cmd('HexGoto 0')
    vim.cmd('HexSearch ascii A')
    settled(s, 1, 3)
    vim.cmd('HexGoto 0')
    keys('3n')
    settled(s, 5, 3)
    H.eq(s.search.wrapped, false)
    vim.cmd('HexGoto 0')
    keys('4n')
    settled(s, 1, 3)
    H.eq(s.search.wrapped, true)
    keys('<Esc>')
    H.eq(api.get_status(s.bufnr).search_text, '')
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.bufnr, view.namespace, 0, -1, { details = true })) do
      assert(not (mark[4].hl_group or ''):find('HexSearch', 1, true))
    end
    view.render(s)
    H.eq(api.get_status(s.bufnr).search_text, '')
    keys('n')
    assert(vim.wait(2000, function() return api.get_status(s.bufnr).search_text ~= '' end, 10))
  end },
  { name = 'UX cancelled native input retains prior search and no old navigation', run = function()
    local s = open('xAxAxA')
    vim.cmd('HexSearch ascii A')
    settled(s, 1, 3)
    local prior = s.cursor.offset
    keys('/5<Esc>')
    H.eq(s.cursor.offset, prior)
    H.eq(s.search.query.kind, 'ascii')
    H.eq(api.get_status(s.bufnr).search_text, '1/3')
    keys('/? <Esc>')
    H.eq(s.search.query.bytes, 'A')
  end },
  { name = 'UX native command-line editing and history retain binary semantics', run = function()
    local old_register, old_search = vim.fn.getreg('a'), vim.fn.getreg('/')
    local seen = {}
    local group = vim.api.nvim_create_augroup('HexitUXCmdlineTest', { clear = true })
    vim.api.nvim_create_autocmd('CmdlineChanged', { group = group, pattern = { '/', '?' },
      callback = function()
        seen[#seen + 1] = { vim.fn.getcmdtype(), vim.fn.getcmdline(), vim.o.incsearch, vim.o.hlsearch }
      end })
    local old_inc, old_hl = vim.o.incsearch, vim.o.hlsearch
    local ok, err = xpcall(function()
      vim.o.incsearch, vim.o.hlsearch = true, true
      vim.fn.setreg('/', 'unchanged-native')
      vim.fn.setreg('a', '41')
      local s = open('ABAB')
      keys('/4<C-u><C-r>a<CR>')
      settled(s, 2, 2)
      H.eq(s.search.query.bytes, 'A')
      H.eq(vim.fn.histget('search', -1), '41')
      keys('/<Up><CR>')
      settled(s, 0, 2)
      H.eq(vim.fn.getreg('/'), 'unchanged-native')
      H.eq(vim.o.incsearch, true)
      H.eq(vim.o.hlsearch, true)
      assert(#seen >= 2)
      for _, record in ipairs(seen) do
        H.eq(record[1], '/')
        H.eq(record[3], false)
        H.eq(record[4], false)
      end
    end, debug.traceback)
    vim.api.nvim_del_augroup_by_id(group)
    vim.fn.setreg('a', old_register)
    vim.fn.setreg('/', old_search)
    vim.o.incsearch, vim.o.hlsearch = old_inc, old_hl
    if not ok then error(err) end
  end },
  { name = 'UX zero-result message appears once and repaint does not repeat it', run = function()
    local s = open('abc')
    local previous_echo = vim.api.nvim_echo
    local messages = {}
    vim.api.nvim_echo = function(chunks, history, opts)
      messages[#messages + 1] = { chunks[1][1], history }
      return previous_echo(chunks, history, opts)
    end
    local ok, err = xpcall(function()
      keys('/FE<CR>')
      assert(vim.wait(2000, function()
        return s.search and s.search.total == 0 and not s.search.pending
      end, 10))
      H.eq(api.get_status(s.bufnr).search_text, '0/0')
      H.eq(messages[#messages], { 'hexit: Pattern not found', false })
      local before = #messages
      view.render(s)
      vim.wait(40, function() return false end, 10)
      H.eq(#messages, before)
      keys('<Esc>')
      H.eq(api.get_status(s.bufnr).search_text, '')
      keys('n')
      assert(vim.wait(2000, function() return #messages > before end, 10))
      H.eq(messages[#messages], { 'hexit: Pattern not found', false })
    end, debug.traceback)
    vim.api.nvim_echo = previous_echo
    if not ok then error(err) end
  end },
  { name = 'UX nested expression input waits for outer search and rejects suffix literally', run = function()
    local original_inc, original_hl = vim.o.incsearch, vim.o.hlsearch
    local old_native = vim.fn.getreg('/')
    local inner = {}
    local group = vim.api.nvim_create_augroup('HexitUXNestedTest', { clear = true })
    vim.api.nvim_create_autocmd('CmdlineLeave', { group = group, pattern = '=',
      callback = function()
        inner[#inner + 1] = { vim.o.incsearch, vim.o.hlsearch,
          api.get_status().input_kind, vim.fn.getcmdtype() }
      end })
    local prior_echo, messages = vim.api.nvim_echo, {}
    vim.api.nvim_echo = function(chunks, history, opts)
      messages[#messages + 1] = chunks[1][1]
      return prior_echo(chunks, history, opts)
    end
    local ok, err = xpcall(function()
      vim.o.incsearch, vim.o.hlsearch = true, true
      vim.fn.setreg('/', 'native-stays')
      local s = open('AA')
      keys("/<C-r>='41'<CR><CR>")
      settled(s, 1, 2)
      H.eq(s.search.query.bytes, 'A')
      H.eq(inner[#inner], { false, false, 'hex', '=' })
      H.eq(vim.fn.getreg('/'), 'native-stays')
      keys('/41/e<CR>')
      assert(vim.wait(1000, function()
        return messages[#messages] == 'hexit: invalid hex search pattern'
      end, 10), vim.inspect(messages))
      H.eq(s.search.query.bytes, 'A')
      H.eq(s.cursor.offset, 1)
    end, debug.traceback)
    vim.api.nvim_echo = prior_echo
    vim.api.nvim_del_augroup_by_id(group)
    vim.o.incsearch, vim.o.hlsearch = original_inc, original_hl
    vim.fn.setreg('/', old_native)
    if not ok then error(err) end
  end },
  { name = 'UX buffer switch during native input drops stale scheduled search', run = function()
    local old_inc, old_hl = vim.o.incsearch, vim.o.hlsearch
    local ordinary = vim.api.nvim_create_buf(true, false)
    local group = vim.api.nvim_create_augroup('HexitUXSwitchTest', { clear = true })
    local ok, err = xpcall(function()
      vim.o.incsearch, vim.o.hlsearch = true, true
      local s = open('ABAB')
      vim.cmd('HexSearch ascii A')
      settled(s, 2, 2)
      vim.api.nvim_create_autocmd('CmdlineChanged', { group = group, pattern = '/',
        once = true, callback = function()
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(ordinary) then vim.api.nvim_set_current_buf(ordinary) end
          end)
        end })
      keys('/42<CR>')
      assert(vim.wait(2000, function() return vim.api.nvim_get_current_buf() == ordinary end, 10))
      vim.wait(40, function() return false end, 10)
      H.eq(s.search.query.kind, 'ascii')
      H.eq(s.cursor.offset, 2)
      H.eq(vim.o.incsearch, true)
      H.eq(vim.o.hlsearch, true)
      H.eq(s.input.search_kind, nil)
    end, debug.traceback)
    vim.api.nvim_del_augroup_by_id(group)
    vim.o.incsearch, vim.o.hlsearch = old_inc, old_hl
    if vim.api.nvim_buf_is_valid(ordinary) then vim.api.nvim_buf_delete(ordinary, { force = true }) end
    if not ok then error(err) end
  end },
}
