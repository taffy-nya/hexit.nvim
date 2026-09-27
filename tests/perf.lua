-- Performance and resource acceptance for the 50 MiB scenarios in
-- .agent/impl-plan/03-testing.md §4.
--
--   nvim --headless -u tests/minimal_init.lua -i NONE -l tests/perf.lua
--
-- Local runs enforce the documented wall-clock thresholds. Shared CI runners are
-- noisy, so HEXIT_PERF_CI=1 keeps reporting the numbers but only enforces the
-- deterministic parts (exact match totals, bounded viewport, no per-hit tables).
-- Set HEXIT_PERF_OUT to choose the JSON report path (default tmp/perf.json).

local uv = vim.uv
local document = require('hexit.document')
local search = require('hexit.search')
local sessions = require('hexit.session')
local actions = require('hexit.actions')
local view = require('hexit.view')

local CI = os.getenv('HEXIT_PERF_CI') == '1'
local OUT = os.getenv('HEXIT_PERF_OUT') or 'tmp/perf.json'
local MIB = 1024 * 1024
local FILE_SIZE = 50 * MIB
local EDIT_COUNT = tonumber(os.getenv('HEXIT_PERF_EDITS') or '') or 10000

local THRESHOLDS = {
  open_ms = 2000,
  heartbeat_ms = 100,
  nav_p95_ms = 50,
  nav_max_ms = 100,
  search_ms = 15000,
  dense_response_ms = 100,
  fill_step_ms = 300,
  rss_ratio = 4,
  dense_rss_bytes = 32 * MIB,
  edit_p95_ms = 100,
  browse_ratio = 4,
}

local report = {
  thresholds = THRESHOLDS,
  enforced = not CI,
  edit_count = EDIT_COUNT,
  scenarios = {},
  correctness_failures = {},
}
local hard_failed = false

local function fail_correctness(name, detail)
  report.correctness_failures[#report.correctness_failures + 1] = name .. ': ' .. detail
  hard_failed = true
end

local function percentile(values, fraction)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  return sorted[math.max(1, math.ceil(#sorted * fraction))]
end

local function median(values)
  return percentile(values, 0.5)
end

-- table.unpack overflows the stack for 10k samples, so max is a plain scan.
local function maxof(values)
  local result = -math.huge
  for _, value in ipairs(values) do
    if value > result then result = value end
  end
  return result
end

local function ms(nanoseconds)
  return nanoseconds / 1000000
end

local function timed(fn)
  local started = uv.hrtime()
  fn()
  return ms(uv.hrtime() - started)
end

local function lua_heap()
  return collectgarbage('count') * 1024
end

local function rss()
  return uv.resident_set_memory()
end

-- Windows-only cross-check: libuv resident memory under-reports the file data
-- (Neovim 0.12 keeps large fs_read results off the Lua heap), so the report also
-- carries the OS working set and private commit from Get-Process.
local function os_memory_bytes()
  if uv.os_uname().sysname ~= 'Windows_NT' then return nil end
  local pid = uv.os_getpid()
  local out = vim.fn.system({ 'powershell', '-NoProfile', '-Command',
    ("$p=Get-Process -Id %d; '{0} {1}' -f $p.WorkingSet64,$p.PrivateMemorySize64"):format(pid) })
  local working, private = out:match('(%d+)%s+(%d+)')
  return tonumber(working), tonumber(private)
end

-- Records event-loop heartbeat gaps while the loop is pumped.
local function heartbeat()
  local timer = assert(uv.new_timer())
  local last = uv.hrtime()
  local worst = 0
  timer:start(10, 10, function()
    local current = uv.hrtime()
    worst = math.max(worst, ms(current - last))
    last = current
  end)
  return {
    stop = function()
      timer:stop()
      timer:close()
      return worst
    end,
  }
end

local function wait_for(predicate, timeout_ms, label)
  if not vim.wait(timeout_ms, predicate, 5) then
    error(('perf wait timeout: %s'):format(label), 2)
  end
end

local root
local root_path
local function tmp_root()
  if root then return root end
  local base = vim.fn.getcwd():gsub('\\', '/') .. '/tmp'
  uv.fs_mkdir(base, 493)
  root = base .. ('/perf-%d'):format(uv.os_getpid())
  assert(uv.fs_mkdir(root, 448))
  root_path = root
  return root
end

-- The marker fixture is 0x41 everywhere except the four Bytes DE AD BE EF at
-- every 1 MiB boundary, so expected hit totals are derivable without an oracle
-- scan. Chunks are generated one at a time and never held as a 50 MiB array.
local DEADBEEF = string.char(0xDE, 0xAD, 0xBE, 0xEF)
local function patterned_chunk(offset, take)
  local body = string.rep('A', take)
  if offset % MIB == 0 and take >= 4 then
    body = DEADBEEF .. body:sub(5)
  end
  return body
end

local function zeros_chunk(_, take)
  return string.rep(string.char(0), take)
end

local function make_fixture(name, size, chunk)
  local path = tmp_root() .. '/' .. name
  local fd = assert(uv.fs_open(path, 'w', 384))
  local offset = 0
  while offset < size do
    local take = math.min(MIB, size - offset)
    local data = chunk(offset, take)
    local written = 0
    while written < #data do
      local count = assert(uv.fs_write(fd, data:sub(written + 1), offset + written))
      assert(count > 0)
      written = written + count
    end
    offset = offset + take
  end
  assert(uv.fs_fsync(fd))
  assert(uv.fs_close(fd))
  return path
end

local function open_session(path)
  local session = require('hexit').open(path)
  wait_for(function()
    return session.phase == 'ready' or session.phase == 'error'
  end, 120000, 'open ' .. path)
  assert(session.phase == 'ready', session.error or 'session failed to load')
  return session
end

local function close_session(session)
  sessions.close(session)
  if vim.api.nvim_buf_is_valid(session.bufnr) then
    vim.api.nvim_buf_delete(session.bufnr, { force = true })
  end
end

local function keys(text)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), 'xt', false)
end

local function add(name, metrics, notes)
  local entry = { name = name, metrics = metrics, notes = notes or {} }
  report.scenarios[#report.scenarios + 1] = entry
  return entry
end

local function enforce(entry, key, value, limit, label)
  entry.metrics[key] = value
  local ok = value <= limit
  entry['within_' .. key] = ok
  if not ok then
    local detail = ('%s: %s = %.2f exceeds %.2f'):format(entry.name, label or key, value, limit)
    if CI then
      entry.notes[#entry.notes + 1] = 'CI report only: ' .. detail
    else
      fail_correctness(entry.name, detail)
    end
  end
end

local function assert_viewport(session)
  local lines = vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
  local limit = math.max(vim.api.nvim_win_get_height(0), session.height) + 1
  if #lines > limit then
    fail_correctness('viewport', ('%d rendered lines exceed %d'):format(#lines, limit))
  end
  return #lines
end

local function scenario_open(fixture, runs)
  local durations, worst_gap = {}, 0
  local session
  for _ = 1, runs do
    local beat = heartbeat()
    durations[#durations + 1] = timed(function() session = open_session(fixture) end)
    worst_gap = math.max(worst_gap, beat.stop())
    close_session(session)
    collectgarbage('collect')
  end
  local duration = median(durations)
  local entry = add('open-50m', {
    runs = runs,
    median_ms = duration,
    samples_ms = durations,
    heartbeat_ms = worst_gap,
  })
  enforce(entry, 'median_ms', duration, THRESHOLDS.open_ms, 'median open to ready')
  enforce(entry, 'heartbeat_ms', worst_gap, THRESHOLDS.heartbeat_ms, 'max heartbeat gap during load')
  return entry
end

local function scenario_navigation(fixture)
  local session = open_session(fixture)
  assert_viewport(session)
  local durations = {}
  for index = 1, 100 do
    local step = index % 5
    if step == 0 then
      durations[#durations + 1] = timed(function() keys('G') end)
    elseif step == 1 then
      durations[#durations + 1] = timed(function() keys('gg') end)
    elseif step == 2 then
      durations[#durations + 1] = timed(function() keys('<C-f>') end)
    elseif step == 3 then
      durations[#durations + 1] = timed(function() keys('<C-b>') end)
    else
      local offset = (index * 7919) % session.root.size
      durations[#durations + 1] = timed(function() vim.cmd('HexGoto ' .. offset) end)
    end
    durations[#durations + 1] = timed(function() keys('rF') end)
  end
  local entry = add('navigation-and-edit', {
    operations = #durations,
    p50_ms = percentile(durations, 0.5),
    p95_ms = percentile(durations, 0.95),
    max_ms = maxof(durations),
    rendered_lines = assert_viewport(session),
    pieces = #session.root.pieces,
  })
  enforce(entry, 'p95_ms', entry.metrics.p95_ms, THRESHOLDS.nav_p95_ms, 'p95 navigation/edit latency')
  enforce(entry, 'max_ms', entry.metrics.max_ms, THRESHOLDS.nav_max_ms, 'max navigation/edit latency')
  close_session(session)
end

-- G/goto/render latency must not scale with the document size.
local function scenario_browse_scaling(navigation_fixture, small_fixture)
  local function browse(path)
    local session = open_session(path)
    local durations = {}
    for index = 1, 40 do
      local offset = (index * 4099) % session.root.size
      durations[#durations + 1] = timed(function() vim.cmd('HexGoto ' .. offset) end)
      durations[#durations + 1] = timed(function() keys('G') end)
      durations[#durations + 1] = timed(function() keys('gg') end)
    end
    close_session(session)
    return median(durations)
  end
  local small = browse(small_fixture)
  local large = browse(navigation_fixture)
  local ratio = large / math.max(small, 0.0001)
  local entry = add('browse-scaling', { ms_5m = small, ms_50m = large, ratio = ratio })
  enforce(entry, 'ratio', ratio, THRESHOLDS.browse_ratio, '50 MiB / 5 MiB browse latency ratio')
end

local function run_full_search(session, kind, pattern, ignorecase)
  local query, err = search.parse(kind, pattern,
    { search_ignorecase = ignorecase, search_smartcase = false })
  assert(query, err)
  local beat = heartbeat()
  local elapsed = timed(function()
    search.start(session, query, 1, 1)
    wait_for(function()
      local state = session.search
      return state and state.total ~= nil
    end, 300000, 'search total ' .. kind .. ' ' .. pattern)
  end)
  local gap = beat.stop()
  return elapsed, gap, session.search.total, session.search
end

local function scenario_search(navigation_fixture, zero_fixture)
  local session = open_session(navigation_fixture)

  local hex_expected = 50
  local hex_elapsed, hex_gap, hex_total = run_full_search(session, 'hex', 'DEADBEEF', false)
  local hex_entry = add('search-hex-4byte', {
    seconds = hex_elapsed / 1000, heartbeat_ms = hex_gap, total = hex_total, expected = hex_expected,
  })
  enforce(hex_entry, 'search_ms', hex_elapsed, THRESHOLDS.search_ms, 'full 4 Byte hex count')
  enforce(hex_entry, 'heartbeat_ms', hex_gap, THRESHOLDS.heartbeat_ms, 'heartbeat gap during hex search')
  if hex_total ~= hex_expected then
    fail_correctness('search-hex-4byte', ('total %s ~= %d'):format(hex_total, hex_expected))
  end

  -- 'A' everywhere except four marker Bytes per MiB: overlapping AAAA hits.
  local ascii_expected = 50 * (MIB - 4 - 3)
  search.cancel(session)
  local ascii_elapsed, ascii_gap, ascii_total, ascii_state = run_full_search(session, 'ascii', 'aaaa', true)
  local ascii_entry = add('search-ascii-ignorecase', {
    seconds = ascii_elapsed / 1000, heartbeat_ms = ascii_gap, total = ascii_total,
    expected = ascii_expected, index_blocks = ascii_state.index and ascii_state.index.blocks or 0,
  })
  enforce(ascii_entry, 'search_ms', ascii_elapsed, THRESHOLDS.search_ms, 'full ASCII ignorecase count')
  enforce(ascii_entry, 'heartbeat_ms', ascii_gap, THRESHOLDS.heartbeat_ms, 'heartbeat gap during ASCII search')
  if ascii_total ~= ascii_expected then
    fail_correctness('search-ascii-ignorecase', ('total %s ~= %d'):format(ascii_total, ascii_expected))
  end
  close_session(session)

  -- 50 MiB of zeros: every Byte is an overlapping hit, so the index must stay
  -- block-based and the search must stay cancellable.
  local zeros = open_session(zero_fixture)
  collectgarbage('collect')
  local before, heap_before = rss(), lua_heap()
  local query = assert(search.parse('hex', '00', {}))
  local response = timed(function() search.start(zeros, query, 1, 1) end)
  wait_for(function()
    local state = zeros.search
    return state and state.total ~= nil
  end, 300000, 'zero search total')
  local state = zeros.search
  local total_zeros = state.total
  local index_blocks = state.index and state.index.blocks or 0
  local cancel_ms = timed(function() search.cancel(zeros) end)
  collectgarbage('collect')
  local stable = rss()
  local dense_entry = add('search-dense-zeros', {
    total = total_zeros,
    expected = FILE_SIZE,
    response_ms = response,
    cancel_ms = cancel_ms,
    index_blocks = index_blocks,
    expected_blocks = math.ceil(FILE_SIZE / 65536),
    rss_delta_bytes = stable - before,
    heap_after_bytes = lua_heap(),
  })
  enforce(dense_entry, 'response_ms', response, THRESHOLDS.dense_response_ms, 'dense search start response')
  enforce(dense_entry, 'cancel_ms', cancel_ms, THRESHOLDS.dense_response_ms, 'dense search cancel')
  enforce(dense_entry, 'rss_delta_bytes', stable - before, THRESHOLDS.dense_rss_bytes, 'dense match RSS')
  if total_zeros ~= FILE_SIZE then
    fail_correctness('search-dense-zeros', ('total %s ~= %d'):format(total_zeros, FILE_SIZE))
  end
  if index_blocks ~= math.ceil(FILE_SIZE / 65536) then
    fail_correctness('search-dense-zeros', ('index blocks %s'):format(index_blocks))
  end
  close_session(zeros)
end

local function scenario_rss(fixture)
  collectgarbage('collect')
  local baseline = rss()
  local base_working, base_private = os_memory_bytes()
  local session = open_session(fixture)
  local loaded = rss()
  local load_working, load_private = os_memory_bytes()
  collectgarbage('collect')
  local stable = rss()
  local stable_working, stable_private = os_memory_bytes()
  local entry = add('rss-after-open', {
    baseline_bytes = baseline,
    loaded_bytes = loaded,
    stable_bytes = stable,
    extra_bytes = stable - baseline,
    os_working_set_delta_bytes = stable_working and (stable_working - base_working) or nil,
    os_private_commit_delta_bytes = stable_private and (stable_private - base_private) or nil,
    load_private_commit_delta_bytes = load_private and (load_private - base_private) or nil,
    os_working_set_load_delta_bytes = load_working and (load_working - base_working) or nil,
    ratio = (stable - baseline) / FILE_SIZE,
    file_bytes = FILE_SIZE,
  })
  enforce(entry, 'ratio', entry.metrics.ratio, THRESHOLDS.rss_ratio, 'extra RSS / file size')
  if entry.metrics.os_private_commit_delta_bytes then
    enforce(entry, 'os_ratio', entry.metrics.os_private_commit_delta_bytes / FILE_SIZE,
      THRESHOLDS.rss_ratio, 'extra private commit / file size')
  end
  close_session(session)
end

local function patch_bytes(session, start, len, byte)
  local intact = 0
  for chunk in document.iter(session.root, start, len, 65536) do
    for index = 1, #chunk do
      if chunk:byte(index) == byte then intact = intact + 1 end
    end
  end
  return intact
end

local function scenario_fill(fixture)
  local session = open_session(fixture)
  local fill = document.from_chunks({ string.rep(string.char(0x5A), MIB) })
  local beat = heartbeat()
  actions.begin(session)
  local apply_ms = timed(function() actions.apply(session, 0, MIB, fill) end)
  local commit_ms = timed(function() actions.commit(session) end)
  wait_for(function() return session.pending == nil end, 60000, 'fill commit compare')
  local gap = beat.stop()
  local undo_ms = timed(function() actions.history(session, false, 1) end)
  local restored_bytes = patch_bytes(session, 0, MIB, 0x41)
  local history_depth, redo_depth = #session.undo, #session.redo
  local redo_ms = timed(function() actions.history(session, true, 1) end)
  local entry = add('fill-1m-undo', {
    apply_ms = apply_ms, commit_ms = commit_ms, undo_ms = undo_ms, redo_ms = redo_ms,
    heartbeat_ms = gap,
    restored_bytes = restored_bytes,
    restored_expected = MIB - 4,
    filled_bytes_after_redo = patch_bytes(session, 0, MIB, 0x5A),
    history_depth = history_depth,
    redo_depth = redo_depth,
  })
  for _, key in ipairs({ 'apply_ms', 'commit_ms', 'undo_ms', 'redo_ms' }) do
    enforce(entry, key, entry.metrics[key], THRESHOLDS.fill_step_ms, key)
  end
  enforce(entry, 'heartbeat_ms', gap, THRESHOLDS.heartbeat_ms, 'event loop gap during 1 MiB fill')
  if restored_bytes ~= MIB - 4 then
    fail_correctness('fill-1m-undo',
      ('undo restored %d pattern Bytes, expected %d'):format(restored_bytes, MIB - 4))
  end
  if entry.metrics.filled_bytes_after_redo ~= MIB or history_depth ~= 0 or redo_depth ~= 1 then
    fail_correctness('fill-1m-undo', 'redo did not restore the filled MiB or history depth is wrong')
  end
  close_session(session)
end

local function scenario_many_edits(fixture)
  local session = open_session(fixture)
  collectgarbage('collect')
  local before, heap_before = rss(), lua_heap()
  local durations = {}
  for index = 1, EDIT_COUNT do
    local value = (index % 2 == 0) and 'F' or '0'
    durations[#durations + 1] = timed(function()
      local ok = actions.replace(session, value, 1)
      if not ok then error('replace rejected at edit ' .. index) end
    end)
  end
  local goto_ms = timed(function() vim.cmd('HexGoto ' .. math.floor(session.root.size / 2)) end)
  local render_ms = timed(function() view.render(session) end)
  collectgarbage('collect')
  local entry = add('discrete-single-byte-edits', {
    edits = EDIT_COUNT,
    p50_ms = percentile(durations, 0.5),
    p95_ms = percentile(durations, 0.95),
    max_ms = maxof(durations),
    goto_ms = goto_ms,
    render_ms = render_ms,
    pieces = #session.root.pieces,
    history = #session.undo,
    lua_heap_bytes = lua_heap(),
    lua_heap_delta_bytes = lua_heap() - heap_before,
    rss_delta_bytes = rss() - before,
    rendered_lines = assert_viewport(session),
  })
  enforce(entry, 'p95_ms', entry.metrics.p95_ms, THRESHOLDS.edit_p95_ms, 'p95 single-Byte edit')
  enforce(entry, 'goto_ms', goto_ms, THRESHOLDS.edit_p95_ms, 'goto after edits')
  enforce(entry, 'render_ms', render_ms, THRESHOLDS.edit_p95_ms, 'render after edits')
  if entry.metrics.history ~= EDIT_COUNT then
    fail_correctness('discrete-single-byte-edits', ('history %d ~= %d'):format(entry.metrics.history, EDIT_COUNT))
  end
  close_session(session)
end

local function environment()
  local uname = uv.os_uname()
  local version = vim.version()
  report.environment = {
    os = ('%s %s %s'):format(uname.sysname, uname.release, uname.machine),
    nvim = ('%d.%d.%d'):format(version.major, version.minor, version.patch),
    lua = jit and jit.version or _VERSION,
    file_size = FILE_SIZE,
    cache = 'warm (fixture written and read in the same run)',
    temp = root_path or 'unknown',
    temp_removed_after_run = root == nil,
    resident_api = 'vim.uv.resident_set_memory',
    ci_report_only = CI,
    started_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
  return report.environment
end

local function write_report()
  environment()
  local directory = vim.fn.fnamemodify(OUT, ':h')
  if directory ~= '' then vim.fn.mkdir(directory, 'p') end
  local fd = assert(uv.fs_open(OUT, 'w', 384))
  assert(uv.fs_write(fd, vim.json.encode(report)))
  assert(uv.fs_close(fd))
end

local function cleanup_fixtures()
  if not root then return end
  local scan = uv.fs_scandir(root)
  if scan then
    while true do
      local name = uv.fs_scandir_next(scan)
      if not name then break end
      uv.fs_unlink(root .. '/' .. name)
    end
  end
  uv.fs_rmdir(root)
  root = nil
end

local function main()
  collectgarbage('collect')
  local navigation_fixture = make_fixture('pattern-50m.bin', FILE_SIZE, patterned_chunk)
  local small_fixture = make_fixture('pattern-5m.bin', 5 * MIB, patterned_chunk)
  local zero_fixture = make_fixture('zeros-50m.bin', FILE_SIZE, zeros_chunk)

  scenario_open(navigation_fixture, 3)
  scenario_navigation(navigation_fixture)
  scenario_browse_scaling(navigation_fixture, small_fixture)
  scenario_rss(navigation_fixture)
  scenario_search(navigation_fixture, zero_fixture)
  scenario_fill(navigation_fixture)
  scenario_many_edits(navigation_fixture)

  cleanup_fixtures()
  write_report()
  local environment_values = report.environment
  print(('PERF env %s nvim=%s'):format(environment_values.os, environment_values.nvim))
  for _, entry in ipairs(report.scenarios) do
    print(('PERF %-28s %s'):format(entry.name, vim.json.encode(entry.metrics)))
  end
  for _, note in ipairs(report.correctness_failures) do
    print('PERF FAIL ' .. note)
  end
  print(('PERF report %s enforced=%s'):format(OUT, tostring(report.enforced)))
  if hard_failed then
    vim.cmd('cquit 1')
  else
    vim.cmd('qa!')
  end
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  print('PERF ERROR ' .. tostring(err))
  pcall(write_report)
  vim.cmd('cquit 1')
end
