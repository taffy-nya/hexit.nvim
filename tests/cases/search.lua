local document = require('hexit.document')
local search = require('hexit.search')

local BLOCK = 64 * 1024
local MIB = 1024 * 1024

local function same(actual, expected, context)
  assert(actual == expected,
    ('%s: expected %s, got %s'):format(context, tostring(expected), tostring(actual)))
end

local function session(root, options, offset)
  return {
    phase = 'ready',
    root = type(root) == 'table' and root or document.from_chunks({ root }),
    revision = 0,
    cursor = { offset = offset or 0, nibble = 0, area = 'hex' },
    preferred_col = nil,
    options = options or {},
    on_change = function() end,
  }
end

local function wait_complete(value)
  assert(vim.wait(30000, function()
    return value.search and not value.search.pending and value.search.total ~= nil
  end, 10), 'search did not finish')
end

local function parse(kind, text, options)
  local query, err = search.parse(kind, text, options or {
    search_ignorecase = false,
    search_smartcase = false,
  })
  assert(query, err)
  return query
end

local function start(value, kind, text, direction, count, options)
  local query = parse(kind, text, options)
  search.start(value, query, direction or 1, count)
  wait_complete(value)
  return value.search
end

local function visible(value, start_at, stop_at)
  local ranges = search.visible_matches(value, start_at, stop_at)
  if #ranges == 0 then
    assert(vim.wait(30000, function()
      local cache = value.search and value.search._visible_cache
      return cache and cache.root == value.root and cache.revision == value.revision
        and cache.start == start_at and cache.stop == stop_at
        and cache.current == value.search.current
    end, 10), 'visible search scan did not finish')
    ranges = search.visible_matches(value, start_at, stop_at)
  end
  return ranges
end

local function case(name, run)
  return { name = name, run = run }
end

return {
  case('SEARCH 1: strict Hex and literal ASCII parsing', function()
    local expected = string.char(0xde, 0xad, 0xbe, 0xef)
    for _, text in ipairs({
      'deadbeef', 'DE AD BE EF', '0xDE 0xad 0xBe 0xef', 'DE 0xad BE 0xef',
    }) do
      same(parse('hex', text).bytes, expected, 'Hex representation ' .. text)
    end
    same(parse('hex', '0xDE').bytes, string.char(0xde), 'single prefixed Byte token')
    same(parse('ascii', 'a.* %', {
      search_ignorecase = false, search_smartcase = false,
    }).bytes, 'a.* %', 'ASCII metacharacters and spaces remain literal')
    local literal = session('a.* aXaa', {}, 0)
    local literal_state = start(literal, 'ascii', 'a.*', 1, 1)
    same(literal_state.total, 1, 'ASCII metacharacters match as literal bytes')
    same(literal.search.current, 0, 'literal match location')

    for _, invalid in ipairs({ 'A', 'AA,BB', '??', 'AA B', '0xAABB', 'GG' }) do
      local query = search.parse('hex', invalid, {})
      same(query, nil, 'reject malformed Hex ' .. invalid)
    end
    local empty = search.parse('ascii', '', {})
    same(empty, nil, 'reject an empty pattern')
    local binary = search.parse('ascii', 'a\0b', {})
    same(binary, nil, 'ASCII rejects NUL')
  end),

  case('SEARCH 2: overlapping hits, counted forward and reverse wrap', function()
    local value = session('aaaa', {}, 0)
    local state = start(value, 'ascii', 'aa', 1, 1)
    same(state.total, 3, 'overlapping match count')
    same(value.cursor.offset, 1, 'first forward result after cursor')
    same(state.ordinal, 2, 'ascending ordinal')
    same(state.direction, 1, 'initial direction')

    local ranges = visible(value, 0, 4)
    same(#ranges, 3, 'current takes priority within overlapping ranges')
    same(ranges[1].start, 0, 'left non-current segment')
    same(ranges[1].stop, 1, 'left segment is clipped before current')
    same(ranges[2].start, 1, 'current segment start')
    same(ranges[2].stop, 3, 'current segment stop')
    same(ranges[2].current, true, 'current segment flag')
    same(ranges[3].start, 3, 'right non-current segment')
    same(ranges[3].stop, 4, 'right segment is clipped after current')

    search.next(value, 1, 2)
    wait_complete(value)
    same(value.cursor.offset, 0, 'count advances past end and wraps')
    same(value.search.ordinal, 1, 'wrapped match keeps ascending ordinal')
    same(value.search.wrapped, true, 'counted navigation reports wrap')

    search.next(value, -1, 4)
    wait_complete(value)
    same(value.cursor.offset, 2, 'backward count reduced modulo total')
    same(value.search.ordinal, 3, 'backward ordinal remains ascending')
    same(value.search.direction, 1, 'N does not change stored direction')
    same(value.search.wrapped, true, 'backward navigation wraps once')

    search.next(value, -1, 1)
    wait_complete(value)
    same(value.cursor.offset, 1, 'backward navigation chooses prior overlapping hit')
    same(value.search.wrapped, false, 'backward direct hit does not wrap')
  end),

  case('SEARCH 3: zero and unique results preserve cursor and wrap once', function()
    local none = session('abcdef', {}, 3)
    local state = start(none, 'ascii', 'missing', 1, 20)
    same(state.total, 0, 'zero match total')
    same(state.ordinal, 0, 'zero match ordinal')
    same(state.current, nil, 'zero matches clear current')
    same(none.cursor.offset, 3, 'zero matches preserve cursor')

    local unique = session('----x', {}, 4)
    state = start(unique, 'ascii', 'x', 1, 1)
    same(unique.cursor.offset, 4, 'forward wrap includes the only match')
    same(state.ordinal, 1, 'wrapped unique ordinal')
    same(state.wrapped, true, 'initial navigation wrapped')
    search.next(unique, 1, 1)
    wait_complete(unique)
    same(unique.cursor.offset, 4, 'unique result can return to itself')
    same(unique.search.wrapped, true, 'self result reports wrap')
  end),

  case('SEARCH 4: ASCII ignorecase and smartcase are captured per query', function()
    local data = 'hello Hello HELLO'
    local function starts_for(text, ignorecase, smartcase)
      local value = session(data, {}, #data - 1)
      local state = start(value, 'ascii', text, 1, 1, {
        search_ignorecase = ignorecase,
        search_smartcase = smartcase,
      })
      local ranges = visible(value, 0, #data)
      local starts = {}
      for _, range in ipairs(ranges) do
        starts[#starts + 1] = range.start
      end
      return state.total, starts, state.query.fold
    end

    local total, starts, fold = starts_for('hello', false, false)
    same(total, 1, 'ignorecase off')
    same(starts[1], 0, 'case-sensitive lowercase start')
    same(fold, false, 'case-sensitive query fold')
    total, starts = starts_for('Hello', false, false)
    same(total, 1, 'uppercase query stays sensitive without ignorecase')
    same(starts[1], 6, 'case-sensitive uppercase result')
    total, starts = starts_for('hello', false, true)
    same(total, 1, 'smartcase alone does not enable ignorecase')
    same(starts[1], 0, 'smartcase lowercase exact result')
    total, starts = starts_for('Hello', false, true)
    same(total, 1, 'smartcase alone leaves uppercase query sensitive')
    same(starts[1], 6, 'smartcase uppercase exact result')
    total, starts = starts_for('hello', true, false)
    same(total, 3, 'ignorecase without smartcase')
    same(starts[2], 6, 'folded second result')
    same(starts[3], 12, 'folded third result')
    total, starts = starts_for('Hello', true, false)
    same(total, 3, 'ignorecase without smartcase folds uppercase query')
    same(starts[1], 0, 'folded uppercase first result')
    same(starts[2], 6, 'folded uppercase second result')
    same(starts[3], 12, 'folded uppercase third result')
    total, starts, fold = starts_for('hello', true, true)
    same(total, 3, 'smartcase lowercase folds')
    same(fold, true, 'lowercase smartcase query fold')
    total, starts, fold = starts_for('Hello', true, true)
    same(total, 1, 'uppercase smartcase query is sensitive')
    same(starts[1], 6, 'uppercase query exact result')
    same(fold, false, 'uppercase smartcase disables folding')

    local old_ignorecase, old_smartcase = vim.o.ignorecase, vim.o.smartcase
    local ok, err = pcall(function()
      vim.o.ignorecase, vim.o.smartcase = true, false
      local captured = parse('ascii', 'captured', {})
      vim.o.ignorecase, vim.o.smartcase = false, true
      same(captured.fold, true, 'nil options capture current vim.o values')
    end)
    vim.o.ignorecase, vim.o.smartcase = old_ignorecase, old_smartcase
    assert(ok, err)

    local bytes = string.char(0xaa, 0xaa, 0xaa)
    local hex = session(bytes, {}, 0)
    local state = start(hex, 'hex', 'aa aa', 1, 1, {
      search_ignorecase = true, search_smartcase = false,
    })
    same(state.total, 2, 'Hex search remains exact and finds overlapping bytes')
    same(hex.cursor.offset, 1, 'Hex fold options do not affect exact bytes')
    same(state.query.fold, false, 'Hex search never folds')
    local binary = session(string.char(0, 255, 0, 255), {}, 0)
    state = start(binary, 'hex', '00 FF', 1, 1)
    same(state.total, 2, 'Hex search matches NUL and 0xFF bytes')
    same(binary.cursor.offset, 2, 'binary Hex navigation result')
  end),

  case('SEARCH 5: scanning crosses block, load-chunk, and piece boundaries', function()
    local second = MIB - 1
    local gap = second - (BLOCK - 1 + 3)
    local root = document.from_chunks({
      string.rep('x', BLOCK - 1) .. 'A',
      'B',
      'C' .. string.rep('y', gap) .. 'A',
      'B',
      'C' .. string.rep('z', 20),
    })
    local value = session(root, {}, 0)
    local state = start(value, 'ascii', 'ABC', 1, 1)
    same(state.total, 2, 'cross-boundary total counts each start once')
    same(value.cursor.offset, BLOCK - 1, 'first hit starts before scan-block edge')
    same(state.ordinal, 1, 'first cross-boundary rank')
    search.next(value, 1, 1)
    wait_complete(value)
    same(value.cursor.offset, second, 'match crosses one-MiB and piece boundaries')
    same(value.search.ordinal, 2, 'second cross-boundary rank')

    local ranges = visible(value, second + 1, second + 3)
    same(#ranges, 1, 'viewport contains clipped cross-edge match')
    same(ranges[1].start, second + 1, 'visible range clips to viewport start')
    same(ranges[1].stop, second + 3, 'visible range clips to viewport stop')
    same(ranges[1].current, true, 'cross-edge current match stays current')
  end),

  case('SEARCH 6: patterns longer than 64 KiB build and scan cooperatively', function()
    local pattern = string.rep('a', BLOCK + 17) .. 'b'
    local offset = BLOCK - 9
    local data = string.rep('z', offset) .. pattern .. string.rep('q', 8)
    local split = offset + math.floor(#pattern / 2)
    local root = document.from_chunks({ data:sub(1, split), data:sub(split + 1) })
    local value = session(root, {}, 0)
    local state = start(value, 'ascii', pattern, 1, 1)
    same(state.total, 1, 'long pattern total')
    same(value.cursor.offset, offset, 'long pattern navigation offset')
    same(state.ordinal, 1, 'long pattern rank')

    local visible_start, visible_stop = offset + 100, offset + 120
    local ranges = visible(value, visible_start, visible_stop)
    same(#ranges, 1, 'long pattern visible halo finds spanning match')
    same(ranges[1].start, visible_start, 'long match clipped at viewport start')
    same(ranges[1].stop, visible_stop, 'long match clipped at viewport end')
    same(ranges[1].current, true, 'long current match remains current')
  end),

  case('SEARCH 7: dense block counts navigate without global hit rows', function()
    local size = 50 * MIB
    local value = session(string.rep('\0', size), {}, 0)
    local state = start(value, 'hex', '00', 1, 1)
    same(state.total, 52428800, '50 MiB dense zero total')
    same(state.index.block_counts[1], BLOCK, 'first block count')
    same(state.index.block_counts[2], BLOCK, 'second block count')
    same(state.index.block_counts[3], BLOCK, 'third block count')
    same(state.index.cumulative[800], size, 'cumulative block rank')
    same(value.cursor.offset, 1, 'dense first next result')
    same(state.ordinal, 2, 'dense ascending rank')

    local ranges = visible(value, 0, 4)
    same(#ranges, 3, 'dense highlight ranges split only for current priority')
    same(ranges[1].start, 0, 'dense pre-current visible segment')
    same(ranges[1].stop, 1, 'dense pre-current boundary')
    same(ranges[2].start, 1, 'dense current segment start')
    same(ranges[2].stop, 2, 'dense current segment stop')
    same(ranges[2].current, true, 'dense current precedence')
    same(ranges[3].start, 2, 'dense post-current visible segment')
    same(ranges[3].stop, 4, 'dense post-current visible boundary')

    search.next(value, 1, 65537)
    wait_complete(value)
    same(value.cursor.offset, 65538, 'counted dense navigation uses rank selection')
    same(value.search.ordinal, 65539, 'dense navigation ordinal')
  end),

  case('SEARCH dense long-pattern viewport stores merged ranges', function()
    local length = BLOCK + 17
    local value = session(string.rep('a', BLOCK * 3), {}, 0)
    start(value, 'ascii', string.rep('a', length), 1, 1)
    search.next(value, 1, BLOCK - 1)
    wait_complete(value)
    same(value.cursor.offset, BLOCK, 'selected dense long-pattern hit')
    local ranges = visible(value, BLOCK - 1, BLOCK + 4)
    same(#ranges, 2, 'visible dense starts merge before priority split')
    same(ranges[1].start, BLOCK - 1, 'ordinary prefix of viewport')
    same(ranges[1].stop, BLOCK, 'ordinary prefix ends at current match')
    same(ranges[2].current, true, 'current long match wins overlap')
    same(ranges[2].stop, BLOCK + 4, 'current match clips at viewport end')
  end),

  case('SEARCH 8: new query, edits, and close invalidate old generations', function()
    local old_root = document.from_chunks({ string.rep('a', BLOCK * 8) .. 'zz' })
    local callbacks = 0
    local value = session(old_root, {}, 0)
    value.on_change = function() callbacks = callbacks + 1 end
    local old = search.parse('ascii', 'a', {
      search_ignorecase = false, search_smartcase = false,
    })
    search.start(value, old, 1, 1)
    local old_state = value.search
    same(old_state.pending, true, 'old query is still pending before replacement')

    local newer = parse('ascii', 'z')
    search.start(value, newer, 1, 1)
    wait_complete(value)
    same(value.search.query, newer, 'new query owns state')
    same(value.search.total, 2, 'old scan cannot overwrite new count')
    same(value.cursor.offset, BLOCK * 8, 'new query owns navigation')

    value.cursor.offset = 0
    value.root = document.from_chunks({ string.rep('z', BLOCK * 4) })
    value.revision = value.revision + 1
    search.on_edit(value)
    local first_edit = value.search
    same(first_edit.pending, true, 'edited snapshot begins a new scan')
    value.root = document.from_chunks({ 'zzzzzz' })
    value.revision = value.revision + 1
    search.on_edit(value)
    wait_complete(value)
    same(value.search.index.root, value.root, 'edit rebuild uses current immutable root')
    same(value.search.total, 6, 'stale edit scan cannot retain old count')
    same(value.search.current, 0, 'edit rebuild restores a matching cursor')
    same(value.search.ordinal, 1, 'edit rebuild recomputes ascending rank')

    value.root = document.from_chunks({ string.rep('z', BLOCK * 4) })
    value.revision = value.revision + 1
    search.start(value, parse('ascii', 'z'), 1, 1)
    local closing_state = value.search
    same(closing_state.pending, true, 'closing snapshot begins a scan')
    value.phase = 'closed'
    value.root = nil
    search.reset(value)
    local after_reset = callbacks
    vim.wait(30, function() return false end, 5)
    same(value.search, nil, 'reset discards all search state')
    same(callbacks, after_reset, 'closed buffer receives no stale redraw')
  end),
  case('SEARCH 9: Esc cancellation retains the query and allows a fresh scan', function()
    local size = BLOCK * 2
    local value = session(string.rep('q', size), {}, 0)
    local query = parse('ascii', 'q')
    search.start(value, query, 1, 1)
    local pending = value.search
    same(pending.pending, true, 'search is pending before Esc')

    search.cancel(value)
    same(value.search.query, query, 'cancel retains the last query')
    same(value.search.pending, false, 'cancel clears pending state')
    same(value.search.total, nil, 'cancel discards incomplete count')
    same(value.search._index_task, nil, 'cancel removes active scan')

    search.next(value, 1, 1)
    wait_complete(value)
    same(value.search.total, size, 'next rebuilds a cancelled index')
    same(value.cursor.offset, 1, 'resumed query navigates from current cursor')
  end),
}
