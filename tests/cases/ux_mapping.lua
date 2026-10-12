local H = require('tests.helpers')

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, true, true), 'xt', false)
end

local function open(data)
  local path = H.temp_file(data)
  vim.cmd('Hex ' .. vim.fn.fnameescape(path))
  return H.wait_ready(vim.api.nvim_get_current_buf()), path
end
local function truth(value)
  return value == true or value == 1
end

local function current_global_map(mode, lhs)
  local wanted = vim.api.nvim_replace_termcodes(lhs, true, false, true)
  for _, map in ipairs(vim.api.nvim_get_keymap(mode)) do
    if map.lhs == lhs or vim.api.nvim_replace_termcodes(map.lhs, true, false, true) == wanted then
      return map
    end
  end
end

local function restore_global_map(mode, lhs, map)
  pcall(vim.keymap.del, mode, lhs)
  if not map then return end
  local opts = {
    remap = not truth(map.noremap),
    silent = truth(map.silent),
    expr = truth(map.expr),
    nowait = truth(map.nowait),
  }
  if map.script ~= nil then opts.script = truth(map.script) end
  if map.desc ~= nil then opts.desc = map.desc end
  if map.replace_keycodes ~= nil then opts.replace_keycodes = truth(map.replace_keycodes) end
  vim.keymap.set(mode, map.lhs or lhs, map.callback or map.rhs, opts)
end

local function finally(run, cleanup)
  local ok, err = xpcall(run, debug.traceback)
  local cleaned, cleanup_err = xpcall(cleanup, debug.traceback)
  if not ok then
    if not cleaned then error(err .. '\ncleanup: ' .. cleanup_err) end
    error(err)
  end
  if not cleaned then error(cleanup_err) end
end

local function with_state(lhses, run)
  local maps = {}
  for _, lhs in ipairs(lhses) do
    maps[#maps + 1] = { lhs = lhs, mapping = current_global_map('n', lhs) }
  end
  local mapleader, maplocalleader = vim.g.mapleader, vim.g.maplocalleader
  finally(run, function()
    local errors = {}
    for _, saved in ipairs(maps) do
      local ok, err = pcall(restore_global_map, 'n', saved.lhs, saved.mapping)
      if not ok then errors[#errors + 1] = err end
    end
    vim.g.mapleader, vim.g.maplocalleader = mapleader, maplocalleader
    if #errors > 0 then error(table.concat(errors, '\n')) end
  end)
end

local group_id = 0
local function with_augroup(name, run)
  local group
  finally(function()
    group_id = group_id + 1
    group = vim.api.nvim_create_augroup(name .. group_id, { clear = true })
    run(group)
  end, function()
    if group then pcall(vim.api.nvim_del_augroup_by_id, group) end
  end)
end


local function value(session)
  return require('hexit.document').read(session.root, 0, session.root.size)
end


return {
  { name = 'UX non-core leader prefix executes global save over local protection', run = function()
    with_state({ ' w' }, function()
      vim.g.mapleader = ' '
      vim.keymap.set('n', ' w', '<Cmd>write<CR>')
      local s, path = open('AB')
      keys('rF')
      H.eq(require('hexit.document').read(s.root, 0, 2), string.char(0xF1) .. 'B')
      keys(' w')
      assert(vim.wait(3000, function() return H.read_disk(path) == string.char(0xF1) .. 'B' end, 10))
      H.eq(vim.bo[s.bufnr].modified, false)
    end)
  end },
  { name = 'UX slash and comma leaders save through global and buffer-local maps', run = function()
    with_state({ '\\w' }, function()
      local cases = { { lhs = '\\w', global = true }, { lhs = ',w', global = false } }
      for _, case in ipairs(cases) do
        vim.g.mapleader = case.lhs:sub(1, 1)
        if case.global then vim.keymap.set('n', case.lhs, '<Cmd>write<CR>') end
        local s, path = open('AB')
        if not case.global then
          vim.keymap.set('n', case.lhs, '<Cmd>write<CR>', { buffer = s.bufnr })
        end
        keys('rF')
        keys(case.lhs)
        assert(vim.wait(3000, function()
          return H.read_disk(path) == string.char(0xF1) .. 'B'
        end, 10), case.lhs)
        H.eq(vim.bo[s.bufnr].modified, false)
      end
    end)
  end },
  { name = 'UX FileType explicit Plug mapping overrides default key after attachment', run = function()
    with_state({}, function()
      with_augroup('HexitUXFileTypeTest', function(group)
        vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'hexit', callback = function(args)
          vim.keymap.set('n', 'h', '<Plug>(Hexit-SwitchArea)', { buffer = args.buf, remap = true })
        end })
        local s = open('AB')
        keys('h')
        H.eq(s.cursor.area, 'ascii')
        H.eq(s.cursor.offset, 0)
      end)
    end)
  end },
  { name = 'UX unsupported operation reports a single native non-history message', run = function()
    with_state({}, function()
      local s = open('AB')
      local echo = vim.api.nvim_echo
      local messages = {}
      vim.api.nvim_echo = function(chunks, history, opts)
        messages[#messages + 1] = { chunks[1][1], history }
        return echo(chunks, history, opts)
      end
      finally(function() keys('x') end, function() vim.api.nvim_echo = echo end)
      H.eq(messages[#messages], { 'hexit: operation not supported yet', false })
      H.eq(value(s), 'AB')
    end)
  end },
  { name = 'UX mapping table merges defaults and routes custom counts prefixes and sequences', run = function()
    with_state({}, function()
      require('hexit').setup({ mappings = {
        s = 'SwitchArea',
        a = 'Right',
        ['!'] = 'Digit2',
        z = 'GPrefix',
        zz = 'Last',
      } })
      local s = open('01234567')
      keys('s')
      keys('a')
      H.eq(s.cursor.offset, 1)
      keys('!a')
      H.eq(s.cursor.offset, 3)
      keys('zz')
      H.eq(s.cursor.offset, 7)
      keys('zg')
      H.eq(s.cursor.offset, 0)
      keys('l')
      H.eq(s.cursor.offset, 1)
    end)
  end },
  { name = 'UX separately typed overlapping explicit mappings select the complete action', run = function()
    local job, timer
    finally(function()
      local path = H.temp_file('01234567')
      job = vim.fn.jobstart({
        vim.v.progpath, '--embed', '--headless', '-u', 'tests/minimal_init.lua', '-i', 'NONE',
      }, { rpc = true })
      assert(job > 0, 'cannot start embedded Neovim')
      local function child(code, ...)
        return vim.rpcrequest(job, 'nvim_exec_lua', code, { ... })
      end
      child([[
        vim.o.timeoutlen = 10000
        require('hexit').setup({ mappings = { z = 'GPrefix', zz = 'Last' } })
        vim.cmd('Hex ' .. vim.fn.fnameescape(...))
        require('tests.helpers').wait_ready(vim.api.nvim_get_current_buf())
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Tab>3l', true, true, true), 'xt', false)
      ]], path)
      local cursor = [[return require('hexit.session').get(vim.api.nvim_get_current_buf()).cursor.offset]]
      H.eq(child(cursor), 3)
      vim.rpcrequest(job, 'nvim_input', 'z')
      -- Send the second key later without non-fast RPC calls interrupting the prefix wait.
      local sent, input_ok, input_err = false, nil, nil
      timer = vim.defer_fn(function()
        if not job then return end
        input_ok, input_err = pcall(vim.rpcrequest, job, 'nvim_input', 'z')
        sent = true
      end, 50)
      assert(vim.wait(2000, function() return sent end, 10), 'second input timed out')
      assert(input_ok, input_err)
      assert(vim.wait(2000, function() return child(cursor) ~= 3 end, 10),
        'complete mapping did not move the cursor')
      H.eq(child(cursor), 7)
    end, function()
      if timer and not timer:is_closing() then timer:stop(); timer:close() end
      if job and job > 0 then
        local stopped = job
        job = nil
        vim.fn.jobstop(stopped)
        vim.fn.jobwait({ stopped }, 2000)
      end
    end)
  end },
  { name = 'UX explicit false passes core and protected keys to existing user maps', run = function()
    with_state({ 'h' }, function()
      with_augroup('HexitUXMappingPass', function(group)
        local global_hits, local_hits = 0, 0
        vim.keymap.set('n', 'h', function() global_hits = global_hits + 1 end)
        vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'hexit', callback = function(args)
          vim.keymap.set('n', 'x', function() local_hits = local_hits + 1 end, { buffer = args.buf })
        end })
        require('hexit').setup({ mappings = { h = false, x = false } })
        local s = open('AB')
        keys('hx')
        H.eq(global_hits, 1)
        H.eq(local_hits, 1)
        H.eq(value(s), 'AB')
        H.eq(s.cursor.offset, 0)
      end)
    end)
  end },
  { name = 'UX disabled and custom-only mapping layers leave user-key fallback', run = function()
    with_state({ 'h', 'x' }, function()
      local hits = { h = 0, x = 0 }
      vim.keymap.set('n', 'h', function() hits.h = hits.h + 1 end)
      vim.keymap.set('n', 'x', function() hits.x = hits.x + 1 end)
      require('hexit').setup({ mappings = false })
      local disabled = open('AB')
      keys('hx')
      H.eq(hits, { h = 1, x = 1 })
      H.eq(value(disabled), 'AB')

      require('hexit').setup({ mappings = {
        defaults = false,
        q = 'Right',
        s = 'SwitchArea',
      } })
      local custom = open('AB')
      keys('sqhx')
      H.eq(custom.cursor.offset, 1)
      H.eq(custom.cursor.area, 'ascii')
      H.eq(hits, { h = 2, x = 2 })
      H.eq(value(custom), 'AB')
    end)
  end },
  { name = 'UX explicit mappings override a prior Hexit Plug while FileType remains later', run = function()
    with_state({ 'q' }, function()
      with_augroup('HexitUXMappingOverride', function(group)
        vim.keymap.set('n', 'q', '<Plug>(Hexit-Left)', { remap = true })
        vim.api.nvim_create_autocmd('FileType', { group = group, pattern = 'hexit', callback = function(args)
          vim.keymap.set('n', 'h', '<Plug>(Hexit-SwitchArea)', { buffer = args.buf, remap = true })
        end })
        require('hexit').setup({ mappings = { q = 'Right', h = 'Right', s = 'SwitchArea' } })
        local s = open('AB')
        keys('sq')
        H.eq(s.cursor.offset, 1)
        keys('h')
        H.eq(s.cursor.area, 'hex')
        H.eq(s.cursor.offset, 1)
      end)
    end)
  end },
  { name = 'UX invalid mapping setup is rejected atomically across active and new sessions', run = function()
    with_state({}, function()
      local hexit = require('hexit')
      hexit.setup({ mappings = { defaults = false, h = 'Right', s = 'SwitchArea' } })
      local first = open('ABCD')
      keys('sh')
      H.eq(first.cursor.offset, 1)
      local invalid = {
        { mappings = 'enabled' },
        { mappings = { defaults = 1 } },
        { mappings = { [''] = 'Right' } },
        { mappings = { [1] = 'Right' } },
        { mappings = { [false] = 'Right' } },
        { mappings = { h = 'UnknownAction' } },
        { mappings = { h = '<Nop>' } },
        { mappings = { h = '<Cmd>let g:unexpected = 1<CR>' } },
        { mappings = { h = true } },
        { mappings = { h = function() end } },
        { mappings = { n = { h = 'Right' } } },
        { mappings = { ['<Tab>'] = 'SwitchArea', ['<C-i>'] = 'Right' } },
      }
      for _, opts in ipairs(invalid) do
        H.eq(pcall(hexit.setup, opts), false)
      end
      local second = open('ABCD')
      keys('sh')
      H.eq(second.cursor.offset, 1)
      hexit.setup({ mappings = {
        defaults = false,
        h = 'Left',
        l = 'Right',
        s = 'SwitchArea',
      } })
      local third = open('ABCD')
      keys('slh')
      H.eq(third.cursor.offset, 0)
      vim.api.nvim_set_current_buf(first.bufnr)
      keys('hh')
      H.eq(first.cursor.offset, 3)
      vim.api.nvim_set_current_buf(second.bufnr)
      keys('h')
      H.eq(second.cursor.offset, 2)
    end)
  end },
  { name = 'UX setup copies mappings isolates sessions and resolves leader immediately', run = function()
    with_state({}, function()
      vim.g.mapleader = ';'
      local opts = { mappings = { defaults = false, ['<leader>m'] = 'Right', s = 'SwitchArea' } }
      require('hexit').setup(opts)
      opts.mappings['<leader>m'] = 'Left'
      vim.g.mapleader = '-'
      local first = open('ABCDE')
      keys('s;m;m')
      H.eq(first.cursor.offset, 2)

      require('hexit').setup({ mappings = {
        defaults = false,
        ['<leader>m'] = 'Left',
        n = 'Right',
        s = 'SwitchArea',
      } })
      local second = open('ABCDE')
      keys('sn-m')
      H.eq(second.cursor.offset, 0)
      vim.api.nvim_set_current_buf(first.bufnr)
      keys(';m')
      H.eq(first.cursor.offset, 3)
    end)
  end },
  { name = 'UX temporary replace and ASCII fill capture released data keys then restore maps', run = function()
    with_state({ 'x', 'y' }, function()
      local global_hits = 0
      vim.keymap.set('n', 'x', function() global_hits = global_hits + 1 end)
      vim.keymap.set('n', 'y', function() global_hits = global_hits + 1 end)
      require('hexit').setup({ mappings = {
        defaults = false,
        s = 'SwitchArea',
        q = 'ReplaceMode',
        r = 'Replace',
        f = 'Replace',
        m = 'Right',
        v = 'Visual',
        u = 'Undo',
        ['<C-r>'] = 'Redo',
        x = false,
        y = false,
        F = false,
      } })
      local s, path = open('abcd')
      keys('sqxy<Esc>')
      H.eq(value(s), 'xycd')
      H.eq(global_hits, 0)
      keys('u')
      H.eq(value(s), 'abcd')
      keys('<C-r>')
      H.eq(value(s), 'xycd')

      keys('xy')
      H.eq(global_hits, 2)
      H.eq(value(s), 'xycd')
      H.eq(s.cursor.offset, 2)
      keys('vmmfx')
      H.eq(value(s), 'xyxx')
      keys('u')
      H.eq(value(s), 'xycd')
      keys('<C-r>')
      H.eq(value(s), 'xyxx')
      keys('xy')
      H.eq(global_hits, 4)
      H.eq(value(s), 'xyxx')

      vim.cmd('write')
      assert(vim.wait(3000, function() return H.read_disk(path) == 'xyxx' end, 10))
      H.eq(vim.bo[s.bufnr].modified, false)
      local hex = open(H.bytes(0xAB, 0xCD))
      keys('rF')
      H.eq(value(hex), H.bytes(0xFB, 0xCD))
      keys('u')
      H.eq(value(hex), H.bytes(0xAB, 0xCD))
      keys('qF<Esc>')
      H.eq(value(hex), H.bytes(0xFB, 0xCD))
      keys('u')
      H.eq(value(hex), H.bytes(0xAB, 0xCD))
    end)
  end },
  { name = 'UX queued combinations are literal Replace data and restore every mapping scope', run = function()
    with_state({ ',w', ',x', '<Space><lt>A' }, function()
      local command_hits, expr_hits, local_hits = 0, 0, 0
      vim.keymap.set('n', ',w', '<Cmd>let g:hexit_mapping_command_hits = g:hexit_mapping_command_hits + 1<CR>')
      local old_hits = vim.g.hexit_mapping_command_hits
      vim.g.hexit_mapping_command_hits = 0
      finally(function()
        vim.keymap.set('n', ',x', function() expr_hits = expr_hits + 1; return 'l' end,
          { expr = true, remap = true })
        vim.keymap.set('n', '<Space><lt>A', function() command_hits = command_hits + 1; return 'l' end,
          { expr = true, remap = true })
        require('hexit').setup({ mappings = { [',a'] = 'SwitchArea' } })
        local original = string.rep('Z', 16)
        local s = open(original)
        vim.keymap.set('n', ',z', function() local_hits = local_hits + 1 end,
          { buffer = s.bufnr, silent = false, nowait = false })
        keys('<Tab>R,a,w,x,z<Space><lt>A<Esc>')
        H.eq(value(s), ',a,w,x,z <A' .. string.rep('Z', 5))
        H.eq(s.cursor.area, 'ascii')
        H.eq({ vim.g.hexit_mapping_command_hits, expr_hits, command_hits, local_hits }, { 0, 0, 0, 0 })
        keys(',a,w,x,z<Space><lt>A')
        H.eq(s.cursor.area, 'hex')
        H.eq({ s.cursor.offset, s.cursor.nibble }, { 12, 0 })
        H.eq({ vim.g.hexit_mapping_command_hits, expr_hits, command_hits, local_hits }, { 1, 1, 1, 1 })
        keys('u')
        H.eq(value(s), original)
        keys('R,a')
        vim.cmd('enew!')
        vim.api.nvim_set_current_buf(s.bufnr)
        H.eq(s.mode, 'normal')
        H.eq(value(s), ',a' .. string.rep('Z', 14))
        keys(',a')
        H.eq(s.cursor.area, 'hex')
        keys('u')
        H.eq(value(s), original)
      end, function() vim.g.hexit_mapping_command_hits = old_hits end)
    end)
  end },
  { name = 'UX native modifier combinations remain data and restore independent mappings', run = function()
    with_state({ 'a<C-I>' }, function()
      local hits = { ci = 0, tab = 0, modified = 0, literal = 0 }
      vim.keymap.set('n', 'a<C-I>', function() hits.ci = hits.ci + 1 end)
      local s, path = open(string.rep('Z', 8))
      vim.keymap.set('n', 'a<Tab>', function() hits.tab = hits.tab + 1; return 'l' end,
        { buffer = s.bufnr, expr = true, remap = true })
      vim.keymap.set('n', 'a<C-R>', function() hits.modified = hits.modified + 1; return 'l' end,
        { buffer = s.bufnr, expr = true, remap = true, silent = false, nowait = false })
      local literal = 'a' .. string.char(18)
      vim.keymap.set('n', literal, function()
        hits.literal = hits.literal + 1
        vim.cmd('HexGoto 6')
      end, { buffer = s.bufnr })
      local ci = vim.fn.maparg('a<C-I>', 'n', false, true).lhsraw
      local tab = vim.fn.maparg('a<Tab>', 'n', false, true).lhsraw
      local modified = vim.fn.maparg('a<C-R>', 'n', false, true).lhsraw
      keys('<Tab>R')
      vim.api.nvim_feedkeys(ci .. tab .. modified .. literal, 'xt', false)
      keys('<Esc>')
      H.eq(value(s), 'aaaaZZZZ')
      H.eq(hits, { ci = 0, tab = 0, modified = 0, literal = 0 })
      vim.cmd('write')
      H.eq(H.read_disk(path), 'aaaaZZZZ')
      keys('u')
      H.eq(value(s), string.rep('Z', 8))
      vim.api.nvim_feedkeys(ci .. tab .. modified .. literal, 'xt', false)
      H.eq(hits, { ci = 1, tab = 1, modified = 1, literal = 1 })
      H.eq(s.cursor.offset, 6)
      H.eq(value(s), string.rep('Z', 8))
      keys('R')
      vim.api.nvim_feedkeys(ci, 'xt', false)
      vim.cmd('enew!')
      vim.api.nvim_set_current_buf(s.bufnr)
      H.eq({ s.mode, value(s) }, { 'normal', string.rep('Z', 6) .. 'aZ' })
      vim.api.nvim_feedkeys(ci, 'xt', false)
      H.eq(hits.ci, 2)
      keys('u')
      H.eq(value(s), string.rep('Z', 8))
    end)
  end },
  { name = 'UX escaped Unicode combinations preserve replacement data and native fallback', run = function()
    with_state({}, function()
      local s = open('ZZZZ')
      local hits = 0
      vim.keymap.set('n', 'a<Char-0x80>', function() hits = hits + 1 end, { buffer = s.bufnr })
      local raw = vim.fn.maparg('a<Char-0x80>', 'n', false, true).lhsraw
      keys('<Tab>R')
      vim.api.nvim_feedkeys(raw, 'xt', false)
      keys('<Esc>')
      H.eq({ value(s), s.mode, hits }, { 'aZZZ', 'normal', 0 })
      keys('u')
      H.eq(value(s), 'ZZZZ')
      vim.api.nvim_feedkeys(raw, 'xt', false)
      H.eq({ value(s), hits }, { 'ZZZZ', 1 })
    end)
  end },
  { name = 'UX single replace Visual fill and Escape replay native modifier suffix identities', run = function()
    with_state({ '<C-I>', '<Tab>' }, function()
      local ci_hits, tab_hits, combo_hits = 0, 0, 0
      vim.keymap.set('n', '<C-I>', function() ci_hits = ci_hits + 1 end)
      vim.keymap.set('n', '<Tab>', function() tab_hits = tab_hits + 1 end)
      require('hexit').setup({ mappings = { s = 'SwitchArea', ['<Tab>'] = false } })
      local s = open('ZZZZ')
      vim.keymap.set('n', 'a<C-I>', function() combo_hits = combo_hits + 1 end, { buffer = s.bufnr })
      vim.keymap.set('n', '<C-[><C-I>', function() combo_hits = combo_hits + 1 end, { buffer = s.bufnr })
      vim.keymap.set('n', 'AB<C-I>', function() combo_hits = combo_hits + 1 end, { buffer = s.bufnr })
      local single = vim.fn.maparg('a<C-I>', 'n', false, true).lhsraw
      local escape = vim.fn.maparg('<C-[><C-I>', 'n', false, true).lhsraw
      local fill = vim.fn.maparg('AB<C-I>', 'n', false, true).lhsraw
      keys('sr')
      vim.api.nvim_feedkeys(single, 'xt', false)
      H.eq({ value(s), s.mode, s.cursor.area }, { 'aZZZ', 'normal', 'ascii' })
      H.eq({ ci_hits, tab_hits, combo_hits }, { 1, 0, 0 })
      keys('uRa')
      vim.api.nvim_feedkeys(escape, 'xt', false)
      H.eq({ value(s), s.mode, s.cursor.area }, { 'aZZZ', 'normal', 'ascii' })
      H.eq({ ci_hits, tab_hits, combo_hits }, { 2, 0, 0 })
      keys('u')
      H.eq(value(s), 'ZZZZ')
      vim.api.nvim_feedkeys(single .. escape, 'xt', false)
      H.eq(combo_hits, 2)
      keys('<Tab>')
      H.eq({ ci_hits, tab_hits }, { 2, 1 })
      keys('sggv2lr')
      vim.api.nvim_feedkeys(fill, 'xt', false)
      H.eq({ value(s), s.mode, s.cursor.area }, { H.bytes(0xAB, 0xAB) .. 'ZZ', 'normal', 'hex' })
      H.eq({ ci_hits, tab_hits, combo_hits }, { 3, 1, 2 })
      keys('u')
      H.eq(value(s), 'ZZZZ')
      vim.api.nvim_feedkeys(fill, 'xt', false)
      H.eq(combo_hits, 3)
    end)
  end },
  { name = 'UX single replace and Visual fill return unconsumed combination keys', run = function()
    with_state({}, function()
      require('hexit').setup({ mappings = {
        a = 'Right', [',a'] = 'SwitchArea', AB = 'SwitchArea', ABl = 'Last',
      } })
      local s = open('ZZZZ')
      keys('<Tab>r,a')
      H.eq(value(s), ',ZZZ')
      H.eq({ s.cursor.area, s.cursor.offset }, { 'ascii', 1 })
      keys(',a')
      keys('ggv2lrABl')
      H.eq(value(s), H.bytes(0xAB, 0xAB) .. 'ZZ')
      H.eq({ s.mode, s.cursor.offset, s.cursor.nibble }, { 'normal', 0, 1 })
      keys('u')
      H.eq(value(s), ',ZZZ')
    end)
  end },
  { name = 'UX queued Escape and Hex colon preserve native suffix ordering', run = function()
    with_state({ '<Esc>x', 'x', ':w<CR>' }, function()
      local combo_hits, tail_hits, write_hits = 0, 0, 0
      vim.keymap.set('n', '<Esc>x', function() combo_hits = combo_hits + 1 end)
      vim.keymap.set('n', 'x', function() tail_hits = tail_hits + 1 end)
      vim.keymap.set('n', ':w<CR>', function() write_hits = write_hits + 1 end)
      require('hexit').setup({ mappings = { x = false } })
      local s, path = open('ABCD')
      keys('R12:w<CR>')
      H.eq(value(s), H.bytes(0x12) .. 'BCD')
      H.eq(H.read_disk(path), H.bytes(0x12) .. 'BCD')
      H.eq({ s.mode, write_hits }, { 'normal', 0 })
      keys('R3<Esc>x')
      H.eq(value(s), H.bytes(0x12, 0x32) .. 'CD')
      H.eq({ s.mode, combo_hits, tail_hits }, { 'normal', 0, 1 })
      keys('<Esc>x')
      H.eq({ combo_hits, tail_hits }, { 1, 1 })
    end)
  end },
}
