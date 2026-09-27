-- Performance and resource acceptance for the 50 MiB scenarios in
-- .agent/impl-plan/03-testing.md §4.
--
--   nvim --headless -u tests/minimal_init.lua -i NONE -l tests/perf.lua
--
-- Every scenario runs HEXIT_PERF_RUNS (default 3) times and reports the median,
-- as the plan requires. Local runs enforce the documented wall-clock thresholds.
-- Shared CI runners are noisy, so HEXIT_PERF_CI=1 keeps reporting the numbers but
-- only enforces the deterministic parts (exact match totals, bounded viewport,
-- block-based dense index, history depth); those always fail.
-- HEXIT_PERF_EDITS only exists for quick local iterations and defaults to the
-- 10,000 edits the plan asks for.
--
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
local RUNS = tonumber(os.getenv('HEXIT_PERF_RUNS') or '') or 3
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
  -- The plan only requires that browsing must not grow linearly with the file
  -- size; 4x is the local bound chosen to enforce that wording.
  browse_ratio = 4,
}

local report = {
  thresholds = THRESHOLDS,
  enforced = not CI,
  runs_per_scenario = RUNS,
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

-- Windows-only cross-check: Neovim 0.12 keeps large fs_read results off the Lua
-- heap, so the report also carries the OS working set and private commit.
local function os_memory_bytes()
  if uv.os_uname().sysname ~= 'Windows_NT' then return nil, nil end
  local pid = uv.os_getpid()
  local out = vim.fn.system({ 'powershell', '-NoProfile', '-Command',
    ("$p=Get-Process -Id %d; '{0} {1}' -f $p.WorkingSet64,$p.PrivateMemorySize64"):format(pid) })
  local working, private = out:match('(%d+)%s+(%d+)')
  return tonumber(working), tonumber(private)
end

local function cpu_name()
  local uname = uv.os_uname()
  if uname.sysname == 'Windows_NT' then
    local ok, out = pcall(vim.fn.system, { 'powershell', '-NoProfile', '-Command',
      '(Get-CimInstance Win32_Processor | Select-Object -First 1).Name' })
    if ok and type(out) == 'string' then
      local name = out:gsub('%s+$', '')
      if name ~= '' then return name end
    end
    return uname.machine
  end
  local ok, lines = pcall(vim.fn.readfile, '/proc/cpuinfo')
  if ok then
    for _, line in ipairs(lines) do
      local name = line:match('^model name%s*:%s*(.+)$')
      if name then return name end
    end
  end
  return uname.machine
end

-- Event-loop responsiveness: vim.wait evaluates its predicate once per loop
-- turn, so the largest gap between two evaluations is the longest time the loop
-- was unable to service new work. A uv timer would be starved the same way but
-- silently stops firing, which is why the gap is sampled from the predicate.
local function gap_tracker()
  local last = uv.hrtime()
  local worst = 0
  return {
    tick = function()
      local current = uv.hrtime()
      worst = math.max(worst, ms(current - last))
      last = current
    end,
    worst = function() return worst end,
  }
end

local function wait_for(predicate, timeout_ms, label, tracker)
  local done = vim.wait(timeout_ms, function()
    if tracker then tracker.tick() end
    return predicate()
  end, 10)
  if not done then
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

local function collect_field(samples, field)
  local values = {}
  for index, sample in ipairs(samples) do values[index] = sample[field] or 0 end
  return values
end

-- Runs the scenario body `times` times, returns every sample table.
local function run_runs(times, fn)
  local samples = {}
  for index = 1, times do
    samples[index] = fn(index)
    collectgarbage('collect')
  end
  return samples
end

local function median_field(samples, field)
  local values = {}
  for _, sample in ipairs(samples) do values[#values + 1] = sample[field] end
  return median(values), values
end

local function max_field(samples, field)
  local best = -math.huge
  for _, sample in ipairs(samples) do best = math.max(best, sample[field]) end
  return best
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

local function write_file(path, content)
  local fd = assert(uv.fs_open(path, 'w', 384))
  assert(uv.fs_write(fd, content))
  assert(uv.fs_close(fd))
end

local function open_session(path, tracker)
  local session = require('hexit').open(path)
  wait_for(function()
    return session.phase == 'ready' or session.phase == 'error'
  end, 120000, 'open ' .. path, tracker)
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

local function scenario_open(fixture)
  local samples = run_runs(RUNS, function()
    local tracker = gap_tracker()
    local session
    local open_ms = timed(function() session = open_session(fixture, tracker) end)
    local heartbeat_ms = tracker.worst()
    close_session(session)
    return { open_ms = open_ms, heartbeat_ms = heartbeat_ms }
  end)
  local open_ms, open_samples = median_field(samples, 'open_ms')
  local heartbeat_ms = max_field(samples, 'heartbeat_ms')
  local entry = add('open-50m', {
    runs = RUNS,
    median_ms = open_ms,
    samples_ms = open_samples,
    max_heartbeat_ms = heartbeat_ms,
  })
  enforce(entry, 'median_ms', open_ms, THRESHOLDS.open_ms, 'median open to ready')
  enforce(entry, 'max_heartbeat_ms', heartbeat_ms, THRESHOLDS.heartbeat_ms, 'max heartbeat gap during load')
end

local function scenario_navigation(fixture)
  local samples = run_runs(RUNS, function()
    local session = open_session(fixture)
    local rendered_lines = assert_viewport(session)
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
    local result = {
      operations = #durations,
      p50_ms = percentile(durations, 0.5),
      p95_ms = percentile(durations, 0.95),
      max_ms = maxof(durations),
      rendered_lines = rendered_lines,
      pieces = #session.root.pieces,
    }
    close_session(session)
    return result
  end)
  local p95_ms, p95_samples = median_field(samples, 'p95_ms')
  local max_ms = max_field(samples, 'max_ms')
  local entry = add('navigation-and-edit', {
    runs = RUNS,
    operations = samples[1].operations,
    median_p95_ms = p95_ms,
    samples_p95_ms = p95_samples,
    max_ms = max_ms,
    rendered_lines = samples[1].rendered_lines,
    pieces = samples[1].pieces,
  })
  enforce(entry, 'median_p95_ms', p95_ms, THRESHOLDS.nav_p95_ms, 'median p95 navigation/edit latency')
  enforce(entry, 'max_ms', max_ms, THRESHOLDS.nav_max_ms, 'max navigation/edit latency')
end

-- G/goto/render latency must not scale with the document size.
local function scenario_browse_scaling(navigation_fixture, small_fixture)
  local function browse(path)
    local samples = run_runs(RUNS, function()
      local session = open_session(path)
      local durations = {}
      for index = 1, 40 do
        local offset = (index * 4099) % session.root.size
        durations[#durations + 1] = timed(function() vim.cmd('HexGoto ' .. offset) end)
        durations[#durations + 1] = timed(function() keys('G') end)
        durations[#durations + 1] = timed(function() keys('gg') end)
      end
      close_session(session)
      return { ms = median(durations) }
    end)
    return median_field(samples, 'ms')
  end
  local small = browse(small_fixture)
  local large = browse(navigation_fixture)
  local ratio = large / math.max(small, 0.0001)
  local entry = add('browse-scaling', {
    runs = RUNS,
    ms_5m = small,
    ms_50m = large,
    ratio = ratio,
  })
  enforce(entry, 'ratio', ratio, THRESHOLDS.browse_ratio, '50 MiB / 5 MiB browse latency ratio')
end

-- 03 §4 asks for "extra RSS relative to an empty process", so the measurement
-- runs in child Neovim processes: one without a document, one that opened the
-- fixture. Offsets are medians over RUNS child pairs.
local RSS_PROBE = [==[
local uv = vim.uv

-- Working set/private commit are Windows-only cross-checks. The portable RSS
-- measurement for every platform remains uv.resident_set_memory().
local function osmem()
  if uv.os_uname().sysname ~= 'Windows_NT' then return nil, nil end

  local out = vim.fn.system({ 'powershell', '-NoProfile', '-Command',
    ("$p=Get-Process -Id %d; '{0} {1}' -f $p.WorkingSet64,$p.PrivateMemorySize64"):format(uv.os_getpid()) })
  local working, private = out:match('(%d+)%s+(%d+)')
  return tonumber(working), tonumber(private)
end

vim.opt.swapfile = false
local path = os.getenv('HEXIT_PERF_PROBE_TARGET')
collectgarbage('collect')
local result = { rss = uv.resident_set_memory(), lua_heap = collectgarbage('count') * 1024 }
result.os_working_set, result.os_private = osmem()
if path and path ~= '' then
  local session = require('hexit').open(path)
  vim.wait(120000, function() return session.phase == 'ready' or session.phase == 'error' end, 5)
  assert(session.phase == 'ready', session.error)
  result.rss = uv.resident_set_memory()
  result.lua_heap = collectgarbage('count') * 1024
  result.os_working_set, result.os_private = osmem()
  collectgarbage('collect')
  result.stable_rss = uv.resident_set_memory()
  result.stable_lua_heap = collectgarbage('count') * 1024
end
io.stdout:write('PROBE ' .. vim.json.encode(result) .. '\n')
vim.cmd('qa!')
]==]

local function probe_environment(fixture)
  local probe = tmp_root() .. '/rss-probe.lua'
  write_file(probe, RSS_PROBE)
  local function child(size)
    local env = { HEXIT_PERF_PROBE_TARGET = fixture or '' }
    local result = vim.system({ 'nvim', '--headless', '-u', 'tests/minimal_init.lua', '-i', 'NONE', '-l', probe },
      { env = env, text = true }):wait()
    assert(result.code == 0, result.stderr or ('probe exit ' .. tostring(result.code)))
    local json = result.stdout and result.stdout:match('PROBE (%b{})')
    assert(json, 'probe produced no measurement')
    return vim.json.decode(json)
  end
  local empty = {}
  local loaded = {}
  for index = 1, RUNS do
    empty[index] = child(nil)
    loaded[index] = child(fixture)
  end
  return empty, loaded
end

local function scenario_rss(fixture)
  local empty, loaded = probe_environment(fixture)

  local function field(samples, name)
    local values = {}
    for _, sample in ipairs(samples) do values[#values + 1] = sample[name] or 0 end
    return median(values)
  end

  local function optional_field(samples, name)
    local values = {}
    for _, sample in ipairs(samples) do
      if sample[name] ~= nil then values[#values + 1] = sample[name] end
    end
    if #values == 0 then return nil end
    return median(values)
  end

  local base_rss = field(empty, 'rss')
  local load_rss = field(loaded, 'rss')
  local stable_rss = field(loaded, 'stable_rss')
  local base_private = optional_field(empty, 'os_private')
  local load_private = optional_field(loaded, 'os_private')
  local base_working = optional_field(empty, 'os_working_set')
  local load_working = optional_field(loaded, 'os_working_set')
  local peak_rss = max_field(loaded, 'rss')
  local entry = add('rss-after-open', {
    runs = RUNS,
    measurement = 'child nvim processes: empty vs opened fixture (median)',
    empty_rss_bytes = base_rss,
    loaded_rss_bytes = load_rss,
    load_peak_rss_bytes = peak_rss,
    stable_rss_bytes = stable_rss,
    extra_rss_bytes = stable_rss - base_rss,
    extra_lua_heap_bytes = field(loaded, 'stable_lua_heap') - field(empty, 'lua_heap'),
    file_bytes = FILE_SIZE,
  })

  -- These values are available only on Windows. Leave them absent elsewhere
  -- instead of reporting a misleading zero measurement.
  if base_working ~= nil and load_working ~= nil then
    entry.metrics.os_working_set_delta_bytes = load_working - base_working
  end
  if base_private ~= nil and load_private ~= nil then
    entry.metrics.os_private_commit_delta_bytes = load_private - base_private
  end

  enforce(entry, 'ratio', entry.metrics.extra_rss_bytes / FILE_SIZE, THRESHOLDS.rss_ratio,
    'extra RSS / file size')
  if entry.metrics.os_private_commit_delta_bytes ~= nil then
    enforce(entry, 'os_ratio', entry.metrics.os_private_commit_delta_bytes / FILE_SIZE, THRESHOLDS.rss_ratio,
      'extra private commit / file size')
  end
end

local function run_full_search(session, kind, pattern, ignorecase)
  local query, err = search.parse(kind, pattern,
    { search_ignorecase = ignorecase, search_smartcase = false })
  assert(query, err)
  local tracker = gap_tracker()
  local started = uv.hrtime()
  local start_ms = timed(function() search.start(session, query, 1, 1) end)
  local wait_ms = timed(function()
    wait_for(function()
      local state = session.search
      return state and state.total ~= nil
    end, 300000, 'search total ' .. kind .. ' ' .. pattern, tracker)
  end)
  local gap = tracker.worst()
  local elapsed = ms(uv.hrtime() - started)
  return elapsed, gap, session.search.total, session.search, start_ms, wait_ms
end

local function scenario_search(navigation_fixture, zero_fixture)
  -- 4 Byte hex pattern, 50 expected hits.
  local hex_samples = run_runs(RUNS, function()
    local session = open_session(navigation_fixture)
    local elapsed, gap, total, _, start_ms, wait_ms = run_full_search(session, 'hex', 'DEADBEEF', false)
    close_session(session)
    return { search_ms = elapsed, heartbeat_ms = gap, total = total, start_ms = start_ms, wait_ms = wait_ms }
  end)
  local hex_expected = 50
  local hex_ms, hex_ms_samples = median_field(hex_samples, 'search_ms')
  local hex_entry = add('search-hex-4byte', {
    runs = RUNS,
    median_ms = hex_ms,
    samples_ms = hex_ms_samples,
    max_heartbeat_ms = max_field(hex_samples, 'heartbeat_ms'),
    start_ms = max_field(hex_samples, 'start_ms'),
    samples_heartbeat_ms = collect_field(hex_samples, 'heartbeat_ms'),
    expected = hex_expected,
  })
  local totals = {}
  for index, sample in ipairs(hex_samples) do totals[index] = sample.total end
  hex_entry.metrics.totals = totals
  enforce(hex_entry, 'median_ms', hex_ms, THRESHOLDS.search_ms, 'median full 4 Byte hex count')
  enforce(hex_entry, 'max_heartbeat_ms', hex_entry.metrics.max_heartbeat_ms,
    THRESHOLDS.heartbeat_ms, 'heartbeat gap during hex search')
  for index, sample in ipairs(hex_samples) do
    if sample.total ~= hex_expected then
      fail_correctness('search-hex-4byte', ('run %d total %s ~= %d'):format(index, sample.total, hex_expected))
    end
  end

  -- 'A' everywhere except four marker Bytes per MiB: overlapping AAAA hits.
  local ascii_expected = 50 * (MIB - 4 - 3)
  local ascii_samples = run_runs(RUNS, function()
    local session = open_session(navigation_fixture)
    local elapsed, gap, total, state, start_ms, wait_ms = run_full_search(session, 'ascii', 'aaaa', true)
    local blocks = state.index and state.index.blocks or 0
    close_session(session)
    return {
      search_ms = elapsed, heartbeat_ms = gap, total = total, index_blocks = blocks,
      start_ms = start_ms, wait_ms = wait_ms,
    }
  end)
  local ascii_ms, ascii_ms_samples = median_field(ascii_samples, 'search_ms')
  local ascii_entry = add('search-ascii-ignorecase', {
    runs = RUNS,
    median_ms = ascii_ms,
    samples_ms = ascii_ms_samples,
    max_heartbeat_ms = max_field(ascii_samples, 'heartbeat_ms'),
    start_ms = max_field(ascii_samples, 'start_ms'),
    samples_heartbeat_ms = collect_field(ascii_samples, 'heartbeat_ms'),
    expected = ascii_expected,
    index_blocks = ascii_samples[1].index_blocks,
  })
  enforce(ascii_entry, 'median_ms', ascii_ms, THRESHOLDS.search_ms, 'median full ASCII ignorecase count')
  enforce(ascii_entry, 'max_heartbeat_ms', ascii_entry.metrics.max_heartbeat_ms,
    THRESHOLDS.heartbeat_ms, 'heartbeat gap during ASCII search')
  for index, sample in ipairs(ascii_samples) do
    if sample.total ~= ascii_expected then
      fail_correctness('search-ascii-ignorecase',
        ('run %d total %s ~= %d'):format(index, sample.total, ascii_expected))
    end
  end

  -- 50 MiB of zeros: every Byte is an overlapping hit. Response and cancel are
  -- measured while the first scan is still running, then a second scan of the
  -- same query must report the exact total from block counts only.
  local expected_blocks = math.ceil(FILE_SIZE / 65536)
  local dense_samples = run_runs(RUNS, function()
    local session = open_session(zero_fixture)
    collectgarbage('collect')
    local heap_before, rss_before = lua_heap(), rss()
    local query = assert(search.parse('hex', '00', {}))
    local response_ms = timed(function() search.start(session, query, 1, 1) end)
    local in_flight = session.search.pending == true and session.search.total == nil
    local cancel_ms = timed(function() search.cancel(session) end)
    local cancelled = session.search.visible == false

    local count_query = assert(search.parse('hex', '00', {}))
    local tracker = gap_tracker()
    local count_ms = timed(function()
      search.start(session, count_query, 1, 1)
      wait_for(function()
        local state = session.search
        return state and state.total ~= nil
      end, 300000, 'zero search total', tracker)
    end)
    local heartbeat_ms = tracker.worst()
    local state = session.search
    local total = state.total
    local blocks = state.index and state.index.blocks or 0
    search.reset(session)
    collectgarbage('collect')
    local heap_delta = lua_heap() - heap_before
    local dense_rss = rss() - rss_before
    close_session(session)
    return {
      response_ms = response_ms, in_flight_cancel = in_flight, cancel_ms = cancel_ms,
      cancelled = cancelled, count_ms = count_ms, heartbeat_ms = heartbeat_ms,
      total = total, index_blocks = blocks, heap_delta_bytes = heap_delta,
      dense_rss_bytes = dense_rss,
    }
  end)
  local response_ms, response_samples = median_field(dense_samples, 'response_ms')
  local cancel_ms = max_field(dense_samples, 'cancel_ms')
  local count_ms = median_field(dense_samples, 'count_ms')
  local dense_entry = add('search-dense-zeros', {
    runs = RUNS,
    response_ms = response_ms,
    samples_response_ms = response_samples,
    cancel_ms = cancel_ms,
    cancel_measured_while_scanning = dense_samples[1].in_flight_cancel,
    cancel_applied = dense_samples[1].cancelled,
    count_ms = count_ms,
    max_heartbeat_ms = max_field(dense_samples, 'heartbeat_ms'),
    expected = FILE_SIZE,
    expected_blocks = expected_blocks,
    index_blocks = dense_samples[1].index_blocks,
    heap_delta_bytes = max_field(dense_samples, 'heap_delta_bytes'),
    dense_rss_bytes = max_field(dense_samples, 'dense_rss_bytes'),
  })
  enforce(dense_entry, 'response_ms', response_ms, THRESHOLDS.dense_response_ms, 'dense search start response')
  enforce(dense_entry, 'cancel_ms', cancel_ms, THRESHOLDS.dense_response_ms, 'dense search cancel during scan')
  enforce(dense_entry, 'heap_delta_bytes', dense_entry.metrics.heap_delta_bytes, THRESHOLDS.dense_rss_bytes,
    'dense search Lua heap growth')
  enforce(dense_entry, 'dense_rss_bytes', dense_entry.metrics.dense_rss_bytes, THRESHOLDS.dense_rss_bytes,
    'dense match RSS growth')
  for index, sample in ipairs(dense_samples) do
    if sample.total ~= FILE_SIZE then
      fail_correctness('search-dense-zeros', ('run %d total %s ~= %d'):format(index, sample.total, FILE_SIZE))
    end
    if sample.index_blocks ~= expected_blocks then
      fail_correctness('search-dense-zeros', ('run %d index blocks %s'):format(index, sample.index_blocks))
    end
    if not sample.in_flight_cancel then
      fail_correctness('search-dense-zeros', ('run %d cancelled after the scan had finished'):format(index))
    end
  end
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
  local samples = run_runs(RUNS, function()
    local session = open_session(fixture)
    local fill = document.from_chunks({ string.rep(string.char(0x5A), MIB) })
    local tracker = gap_tracker()
    actions.begin(session)
    local apply_ms = timed(function() actions.apply(session, 0, MIB, fill) end)
    local commit_ms = timed(function() actions.commit(session) end)
    wait_for(function() return session.pending == nil end, 60000, 'fill commit compare', tracker)
    local heartbeat_ms = tracker.worst()
    local undo_ms = timed(function() actions.history(session, false, 1) end)
    local restored_bytes = patch_bytes(session, 0, MIB, 0x41)
    local history_depth, redo_depth = #session.undo, #session.redo
    local redo_ms = timed(function() actions.history(session, true, 1) end)
    local filled_bytes = patch_bytes(session, 0, MIB, 0x5A)
    close_session(session)
    return {
      apply_ms = apply_ms, commit_ms = commit_ms, undo_ms = undo_ms, redo_ms = redo_ms,
      heartbeat_ms = heartbeat_ms, restored_bytes = restored_bytes,
      filled_bytes_after_redo = filled_bytes, history_depth = history_depth, redo_depth = redo_depth,
    }
  end)
  local entry = add('fill-1m-undo', {
    runs = RUNS,
    apply_ms = median_field(samples, 'apply_ms'),
    commit_ms = median_field(samples, 'commit_ms'),
    undo_ms = median_field(samples, 'undo_ms'),
    redo_ms = median_field(samples, 'redo_ms'),
    max_heartbeat_ms = max_field(samples, 'heartbeat_ms'),
    restored_expected = MIB - 4,
  })
  for _, key in ipairs({ 'apply_ms', 'commit_ms', 'undo_ms', 'redo_ms' }) do
    enforce(entry, key, entry.metrics[key], THRESHOLDS.fill_step_ms, key)
  end
  enforce(entry, 'max_heartbeat_ms', entry.metrics.max_heartbeat_ms, THRESHOLDS.heartbeat_ms,
    'event loop gap during 1 MiB fill')
  for index, sample in ipairs(samples) do
    if sample.restored_bytes ~= MIB - 4 or sample.filled_bytes_after_redo ~= MIB
      or sample.history_depth ~= 0 or sample.redo_depth ~= 1 then
      fail_correctness('fill-1m-undo', ('run %d fill/undo/redo state is wrong'):format(index))
    end
  end
end

local function scenario_many_edits(fixture)
  -- Alternating F/0 edits always land on the high nibble of Byte 0, so the
  -- final content depends only on the parity of the edit count.
  local expected_high = (EDIT_COUNT % 2 == 0) and 0xF or 0x0
  local samples = run_runs(RUNS, function()
    local session = open_session(fixture)
    collectgarbage('collect')
    local before_rss, heap_before = rss(), lua_heap()
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
    local result = {
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
      rss_delta_bytes = rss() - before_rss,
      rendered_lines = assert_viewport(session),
      root_size = session.root.size,
      first_byte = document.read(session.root, 0, 1):byte(),
    }
    close_session(session)
    return result
  end)
  local p95_ms, p95_samples = median_field(samples, 'p95_ms')
  local entry = add('discrete-single-byte-edits', {
    runs = RUNS,
    edits = EDIT_COUNT,
    median_p95_ms = p95_ms,
    samples_p95_ms = p95_samples,
    max_ms = max_field(samples, 'max_ms'),
    goto_ms = median_field(samples, 'goto_ms'),
    render_ms = median_field(samples, 'render_ms'),
    pieces = samples[1].pieces,
    history = samples[1].history,
    lua_heap_bytes = median_field(samples, 'lua_heap_bytes'),
    lua_heap_delta_bytes = median_field(samples, 'lua_heap_delta_bytes'),
    rss_delta_bytes = median_field(samples, 'rss_delta_bytes'),
    rendered_lines = samples[1].rendered_lines,
    root_size = samples[1].root_size,
    expected_high_nibble = expected_high,
  })
  enforce(entry, 'median_p95_ms', p95_ms, THRESHOLDS.edit_p95_ms, 'median p95 single-Byte edit')
  enforce(entry, 'goto_ms', entry.metrics.goto_ms, THRESHOLDS.edit_p95_ms, 'goto after edits')
  enforce(entry, 'render_ms', entry.metrics.render_ms, THRESHOLDS.edit_p95_ms, 'render after edits')
  for index, sample in ipairs(samples) do
    if sample.history ~= EDIT_COUNT then
      fail_correctness('discrete-single-byte-edits',
        ('run %d history %d ~= %d'):format(index, sample.history, EDIT_COUNT))
    end
    if sample.root_size ~= FILE_SIZE or sample.rendered_lines > 22 then
      fail_correctness('discrete-single-byte-edits', ('run %d document/viewport invariant broke'):format(index))
    end
    -- Alternating F/0 edits always land on the high nibble of Byte 0.
    if math.floor(sample.first_byte / 16) ~= expected_high then
      fail_correctness('discrete-single-byte-edits',
        ('run %d last edit not visible: byte0=%02X'):format(index, sample.first_byte))
    end
  end
end

-- 03 §4: exporting the whole file necessarily produces result text, which is not
-- part of the browsing budget but must be recorded separately.
local function scenario_export(fixture)
  local expected_text_bytes = 4 * math.ceil(FILE_SIZE / 3)
  local samples = run_runs(RUNS, function()
    local session = open_session(fixture)
    collectgarbage('collect')
    local before_rss, heap_before = rss(), lua_heap()
    vim.cmd('HexGoto 0')
    local yank_ms = timed(function()
      local ok, err = actions.yank(session, session.root.size)
      assert(ok, err)
    end)
    local register_bytes = actions.register().size

    -- Select the whole document through the real Visual path (0 -> G).
    vim.cmd('HexGoto 0')
    actions.visual(session, 'visual')
    keys('G')
    local selection_start, selection_stop = actions.selection(session)
    assert(selection_start == 0 and selection_stop == session.root.size,
      ('whole-file selection is %s..%s'):format(tostring(selection_start), tostring(selection_stop)))

    local original_setreg = vim.fn.setreg
    local written, completed = nil, false
    vim.fn.setreg = function(target, text, kind)
      written, completed = text, true
      return original_setreg(target, text, kind)
    end
    local ok, err
    local tracker = gap_tracker()
    local copy_ms = timed(function()
      ok, err = pcall(function()
        actions.copy_as(session, 'base64', '"')
        wait_for(function() return completed end, 300000, 'whole-file Base64 export', tracker)
      end)
    end)
    local heartbeat_ms = tracker.worst()
    vim.fn.setreg = original_setreg
    if not ok then error(err) end
    local text_bytes = #written
    local copied_bytes = #vim.fn.getreg('"')
    actions.escape(session)
    local after_rss, after_heap = rss(), lua_heap()
    vim.fn.setreg('"', '', 'v')
    collectgarbage('collect')
    local stable_rss = rss()
    close_session(session)
    return {
      yank_ms = yank_ms, copy_ms = copy_ms, heartbeat_ms = heartbeat_ms,
      text_bytes = text_bytes, copied_bytes = copied_bytes,
      register_bytes = register_bytes, expected_text_bytes = expected_text_bytes,
      rss_delta_bytes = after_rss - before_rss, heap_delta_bytes = after_heap - heap_before,
      stable_rss_delta_bytes = stable_rss - before_rss,
    }
  end)
  local entry = add('export-whole-file', {
    runs = RUNS,
    note = 'result text memory is recorded separately, not part of the browsing budget',
    yank_ms = median_field(samples, 'yank_ms'),
    copy_ms = median_field(samples, 'copy_ms'),
    max_heartbeat_ms = max_field(samples, 'heartbeat_ms'),
    text_bytes = median_field(samples, 'text_bytes'),
    expected_text_bytes = expected_text_bytes,
    register_bytes = median_field(samples, 'register_bytes'),
    rss_delta_bytes = median_field(samples, 'rss_delta_bytes'),
    heap_delta_bytes = median_field(samples, 'heap_delta_bytes'),
    stable_rss_delta_bytes = median_field(samples, 'stable_rss_delta_bytes'),
    file_bytes = FILE_SIZE,
    rss_ratio = median_field(samples, 'rss_delta_bytes') / FILE_SIZE,
  })
  for index, sample in ipairs(samples) do
    if sample.text_bytes ~= expected_text_bytes or sample.copied_bytes ~= expected_text_bytes then
      fail_correctness('export-whole-file',
        ('run %d Base64 text %d/%d ~= %d'):format(index, sample.text_bytes, sample.copied_bytes, expected_text_bytes))
    end
    if sample.register_bytes ~= FILE_SIZE then
      fail_correctness('export-whole-file', ('run %d binary register %d'):format(index, sample.register_bytes))
    end
  end
end

local function environment()
  local uname = uv.os_uname()
  local version = vim.version()
  report.environment = {
    os = ('%s %s %s'):format(uname.sysname, uname.release, uname.machine),
    cpu = cpu_name(),
    nvim = ('%d.%d.%d'):format(version.major, version.minor, version.patch),
    lua = jit and jit.version or _VERSION,
    file_size = FILE_SIZE,
    cache = 'warm (fixture written and read in the same run)',
    temp = root_path or 'unknown',
    temp_removed_after_run = root == nil,
    resident_api = 'vim.uv.resident_set_memory',
    os_memory_api = 'Windows: Get-Process WorkingSet64 / PrivateMemorySize64',
    ci_report_only = CI,
    runs_per_scenario = RUNS,
    started_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
  return report.environment
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

local function write_report()
  environment()
  local directory = vim.fn.fnamemodify(OUT, ':h')
  if directory ~= '' then vim.fn.mkdir(directory, 'p') end
  local fd = assert(uv.fs_open(OUT, 'w', 384))
  assert(uv.fs_write(fd, vim.json.encode(report)))
  assert(uv.fs_close(fd))
end

local function main()
  collectgarbage('collect')
  local navigation_fixture = make_fixture('pattern-50m.bin', FILE_SIZE, patterned_chunk)
  local small_fixture = make_fixture('pattern-5m.bin', 5 * MIB, patterned_chunk)
  local zero_fixture = make_fixture('zeros-50m.bin', FILE_SIZE, zeros_chunk)

  scenario_open(navigation_fixture)
  scenario_navigation(navigation_fixture)
  scenario_browse_scaling(navigation_fixture, small_fixture)
  scenario_rss(navigation_fixture)
  scenario_search(navigation_fixture, zero_fixture)
  scenario_fill(navigation_fixture)
  scenario_export(navigation_fixture)
  scenario_many_edits(navigation_fixture)

  cleanup_fixtures()
  write_report()
  local environment_values = report.environment
  print(('PERF env %s | %s | nvim=%s runs=%d'):format(
    environment_values.os, environment_values.cpu, environment_values.nvim, RUNS))
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
  pcall(cleanup_fixtures)
  pcall(write_report)
  vim.cmd('cquit 1')
end

