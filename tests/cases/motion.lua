local document = require('hexit.document')
local motion = require('hexit.motion')

local function same(actual, expected, context)
  assert(actual == expected, ('%s: expected %s, got %s'):format(context, tostring(expected), tostring(actual)))
end

local function session(data, bpr, area)
  return {
    phase = 'ready',
    root = document.from_chunks({ data }),
    bytes_per_row = bpr or 4,
    cursor = { offset = 0, nibble = 0, area = area or 'hex' },
    preferred_col = nil,
    top_row = 0,
    generation = 0,
  }
end

local function move(s, action, count, has_count, height)
  local calls = 0
  motion.move(s, action, count, has_count, height or 4, function() calls = calls + 1 end)
  return calls
end

local function position(s, offset, nibble, area, context)
  same(s.cursor.offset, offset, context .. ' offset')
  if nibble ~= nil then same(s.cursor.nibble, nibble, context .. ' nibble') end
  if area ~= nil then same(s.cursor.area, area, context .. ' area') end
end

local function case(name, run)
  return { name = name, run = run }
end

return {
  case('NAV 1: hex nibble, byte, and EOF movement', function()
    local s = session('ABC', 4)
    same(move(s, 'Left'), 1, 'left completion')
    position(s, 0, 0, 'hex', 'left at start')
    move(s, 'Right')
    position(s, 0, 1, 'hex', 'right to low nibble')
    move(s, 'Right')
    position(s, 1, 0, 'hex', 'right across byte')
    move(s, 'Left')
    position(s, 0, 1, 'hex', 'left across byte')
    move(s, 'Left')
    position(s, 0, 0, 'hex', 'left clamps at start')
    move(s, 'Right', 100, true)
    position(s, 2, 1, 'hex', 'count clamps at EOF')
    move(s, 'Right')
    position(s, 2, 1, 'hex', 'right clamps at EOF')
    move(s, 'Left', 100, true)
    position(s, 0, 0, 'hex', 'count clamps at start')

    s.cursor.offset, s.cursor.nibble = 1, 1
    move(s, 'WordNext')
    position(s, 2, 0, 'hex', 'hex word next is one byte')
    move(s, 'WordPrev')
    position(s, 1, 0, 'hex', 'hex word previous is one byte')
    move(s, 'WordEnd')
    position(s, 1, 1, 'hex', 'hex word end high nibble')
    move(s, 'WordEnd')
    position(s, 2, 1, 'hex', 'hex word end low nibble')

    s.cursor.area = 'ascii'
    s.cursor.offset = 0
    move(s, 'Right', 2, true)
    position(s, 2, 0, 'ascii', 'ASCII horizontal movement')
    move(s, 'Left', 20, true)
    position(s, 0, 0, 'ascii', 'ASCII horizontal start clamp')
    move(s, 'Right', 20, true)
    position(s, 2, 0, 'ascii', 'ASCII horizontal EOF clamp')
  end),

  case('NAV 2: vertical preferred byte column and viewport', function()
    local s = session('0123456789', 4)
    s.cursor.offset, s.cursor.nibble = 3, 1
    move(s, 'Down', nil, false, 2)
    position(s, 7, 1, 'hex', 'down preserves byte column and nibble')
    same(s.preferred_col, 3, 'preferred column after down')
    same(s.top_row, 0, 'first down keeps visible top')
    move(s, 'Down', nil, false, 2)
    position(s, 9, 1, 'hex', 'short tail temporarily clamps column')
    same(s.top_row, 1, 'scrolls minimally below viewport')
    move(s, 'Up', nil, false, 2)
    position(s, 7, 1, 'hex', 'up restores preferred column')
    move(s, 'Up', nil, false, 2)
    position(s, 3, 1, 'hex', 'up returns to original row')
    same(s.top_row, 0, 'scrolls minimally above viewport')

    move(s, 'Down')
    move(s, 'Right')
    same(s.preferred_col, nil, 'horizontal movement resets preferred column')
    move(s, 'Down')
    position(s, 8, 0, 'hex', 'vertical movement uses new actual column')

    s.bytes_per_row = 2
    s.preferred_col = nil
    s.cursor.offset = 2
    move(s, 'Down')
    position(s, 4, 0, 'hex', 'vertical movement follows updated row width')
  end),

  case('NAV 3: ASCII word classes and hex word nibble rules', function()
    local s = session('ab__  cd!?? ef', 4, 'ascii')
    move(s, 'WordNext')
    position(s, 6, 0, 'ascii', 'w skips word and spaces')
    move(s, 'WordNext')
    position(s, 8, 0, 'ascii', 'w treats punctuation as its own run')
    local counted = session('ab__  cd!?? ef', 4, 'ascii')
    move(counted, 'WordNext', 2, true)
    position(counted, 8, 0, 'ascii', 'counted w repeats run movement')
    move(s, 'WordPrev')
    position(s, 6, 0, 'ascii', 'b returns to previous run start')

    s.cursor.offset = 0
    move(s, 'WordEnd')
    position(s, 3, 0, 'ascii', 'e reaches current word end')
    move(s, 'WordEnd')
    position(s, 7, 0, 'ascii', 'e skips spaces to next word end')
    move(s, 'WordEnd')
    position(s, 10, 0, 'ascii', 'e reaches punctuation-run end')
    move(s, 'WordEnd')
    position(s, 13, 0, 'ascii', 'e skips spaces to final word end')

    s.cursor.offset = 11
    move(s, 'WordPrev')
    position(s, 8, 0, 'ascii', 'b skips whitespace to punctuation start')

    s.root = document.from_chunks({ string.char(65, 0, 255, 32, 66) })
    s.cursor.offset = 0
    move(s, 'WordNext')
    position(s, 1, 0, 'ascii', 'NUL begins punctuation run')
    move(s, 'WordNext')
    position(s, 4, 0, 'ascii', 'high bytes share punctuation class')
    s.cursor.offset = 1
    move(s, 'WordEnd')
    position(s, 2, 0, 'ascii', 'word end reads raw NUL and high byte')
    s.cursor.offset = 4
    move(s, 'WordEnd')
    position(s, 4, 0, 'ascii', 'word end clamps at EOF')
    s.root = document.from_chunks({ string.char(65, 9, 10, 11, 12, 13, 32, 66) })
    s.cursor.offset = 0
    move(s, 'WordNext')
    position(s, 7, 0, 'ascii', 'w treats all ASCII whitespace bytes as whitespace')
    move(s, 'WordPrev')
    position(s, 0, 0, 'ascii', 'b crosses the complete whitespace run')
    move(s, 'WordEnd')
    position(s, 7, 0, 'ascii', 'e skips control whitespace')
  end),

  case('NAV 4: row starts, row ends, gg/G and counted destinations', function()
    local s = session('0123456789', 4)
    s.cursor.offset, s.cursor.nibble = 6, 0
    move(s, 'RowStart')
    position(s, 4, 0, 'hex', 'row start')
    move(s, 'RowEnd')
    position(s, 7, 1, 'hex', 'row end')
    move(s, 'RowEnd', 2, true)
    position(s, 9, 1, 'hex', 'counted row end clamps to short final row')
    move(s, 'First')
    position(s, 0, 0, 'hex', 'gg without count')
    move(s, 'First', 2, true)
    position(s, 4, 0, 'hex', 'counted gg selects requested row start')
    move(s, 'Last', 2, true)
    position(s, 4, 0, 'hex', 'counted G differs from uncounted G')
    move(s, 'Last')
    position(s, 9, 1, 'hex', 'uncounted G selects final low nibble')

    s.cursor.area = 'ascii'
    move(s, 'First')
    position(s, 0, nil, 'ascii', 'ASCII gg retains the byte area')
    move(s, 'Last')
    position(s, 9, nil, 'ascii', 'ASCII G selects final byte')
  end),

  case('NAV 5: half/page row motion and empty-root no-op', function()
    local s = session('01234567890123456789', 4)
    s.cursor.offset, s.cursor.nibble = 5, 1
    move(s, 'PageDown', nil, false, 4)
    position(s, 13, 1, 'hex', 'page down preserves byte column and nibble')
    same(s.top_row, 1, 'page down clamps viewport while retaining visibility')
    move(s, 'PageDown', nil, false, 4)
    position(s, 17, 1, 'hex', 'page down clamps cursor at final row')
    same(s.top_row, 1, 'page down clamps viewport at file end')
    move(s, 'PageUp', nil, false, 4)
    position(s, 9, 1, 'hex', 'page up moves by overlapping page size')
    same(s.top_row, 0, 'page up clamps viewport at file start')
    move(s, 'HalfDown', 2, true, 4)
    position(s, 17, 1, 'hex', 'counted half-page movement clamps')
    move(s, 'First', 5, true, 4)
    position(s, 16, 0, 'hex', 'counted first selects fifth row start')

    local empty = session('', 4)
    for _, action in ipairs({
      'Left', 'Right', 'Up', 'Down', 'WordNext', 'WordPrev', 'WordEnd',
      'First', 'Last', 'RowStart', 'RowEnd', 'HalfUp', 'HalfDown', 'PageUp', 'PageDown',
    }) do
      same(move(empty, action, nil, false, 1), 1, action .. ' empty completion')
      position(empty, 0, 0, 'hex', action .. ' empty no-op')
      same(empty.top_row, 0, action .. ' empty top row')
    end
  end),

  case('NAV 6: cooperative long-word completion and cancellation', function()
    local first = string.rep('a', 70000)
    local second = string.rep('a', 80000)
    local data = first .. second
    local completed = session(data, 16, 'ascii')
    completed.root = document.from_chunks({ first, second })
    local calls = 0
    motion.move(completed, 'WordNext', 1, false, 4, function() calls = calls + 1 end)
    same(calls, 0, 'long ASCII scan yields before completion')
    assert(vim.wait(5000, function() return calls > 0 end, 10), 'long ASCII scan should complete')
    same(calls, 1, 'long ASCII completion callback runs once')
    position(completed, #data - 1, 0, 'ascii', 'long word reaches EOF')

    local cancelled = session(data, 16, 'ascii')
    cancelled.root = document.from_chunks({ first, second })
    calls = 0
    motion.move(cancelled, 'WordNext', 1, false, 4, function() calls = calls + 1 end)
    same(calls, 0, 'cancelled scan is pending')
    motion.cancel(cancelled)
    vim.wait(20, function() return false end, 1)
    same(calls, 0, 'cancelled scan has no completion callback')
    position(cancelled, 0, 0, 'ascii', 'cancelled scan leaves cursor unchanged')
  end),
}
