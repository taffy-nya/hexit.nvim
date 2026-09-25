local document = require('hexit.document')

local function same(actual, expected, context)
  assert(actual == expected, (context or 'values differ') .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
end

local function fails(fn, context)
  local ok, err = pcall(fn)
  assert(not ok, (context or 'operation') .. ' should fail')
  assert(type(err) == 'string', (context or 'operation') .. ' should report an error')
end

local function same_runs(actual, expected, context)
  same(#actual, #expected, context .. ' run count')
  for i, run in ipairs(expected) do
    same(actual[i][1], run[1], context .. ' run ' .. i .. ' start')
    same(actual[i][2], run[2], context .. ' run ' .. i .. ' stop')
  end
end

local function validate_root(root)
  same(#root.pieces, #root.ends, 'piece/end count')
  local total = 0
  local previous
  for i, piece in ipairs(root.pieces) do
    assert(type(piece.data) == 'string' and piece.len > 0, 'pieces must reference non-empty byte ranges')
    assert(piece.start >= 0 and piece.start + piece.len <= #piece.data, 'piece range must be within its source string')
    if previous then
      assert(not (previous.data == piece.data and previous.start + previous.len == piece.start), 'contiguous pieces from the same string must merge')
    end
    total = total + piece.len
    same(root.ends[i], total, 'cumulative piece end')
    previous = piece
  end
  same(root.size, total, 'root size')
end

local function case(name, run)
  return { name = name, run = run }
end

return {
  case('DOC 1: binary chunks and empty slice', function()
    local bytes = string.char(0, 10, 13, 127, 128, 255)
    local root = document.from_chunks({ bytes:sub(1, 2), '', bytes:sub(3, 5), bytes:sub(6) })
    same(root.size, 6, 'binary root size')
    same(document.read(root, 0, root.size), bytes, 'binary read')
    for i = 0, #bytes - 1 do
      same(document.read(root, i, 1), bytes:sub(i + 1, i + 1), 'single-byte read ' .. i)
    end
    same(document.read(root, root.size, 0), '', 'empty end read')
    same(document.slice(document.empty(), 0, 0).size, 0, 'empty root slice')
    same(document.read(document.slice(root, 3, 0), 0, 0), '', 'empty slice read')
    validate_root(root)
  end),

  case('DOC 2: cross-chunk reads, splice, and root immutability', function()
    local root = document.from_chunks({ 'AB', 'CD' })
    local original_pieces, original_ends = root.pieces, root.ends
    local first_piece = root.pieces[1]
    local first_start, first_len, first_end = first_piece.start, first_piece.len, root.ends[1]
    same(document.read(root, 1, 2), 'BC', 'cross-chunk read')

    local result = document.splice(root, 1, 2, document.from_chunks({ 'xyz' }))
    same(document.read(result, 0, result.size), 'AxyzD', 'spliced bytes')
    same(document.equal(root, result), false, 'different contents are not equal')
    same(document.read(root, 0, root.size), 'ABCD', 'old root bytes')
    assert(root.pieces == original_pieces and root.ends == original_ends, 'splice must retain old root arrays')
    assert(root.pieces[1] == first_piece, 'splice must not replace old piece records')
    same(first_piece.start, first_start, 'old piece start')
    same(first_piece.len, first_len, 'old piece length')
    same(root.ends[1], first_end, 'old cumulative end')

    local sliced = document.slice(root, 1, 2)
    same(document.read(sliced, 0, sliced.size), 'BC', 'slice bytes')
    same(document.read(root, 0, root.size), 'ABCD', 'slice must preserve source root')

    local single = document.from_chunks({ 'abcdef' })
    local replacement = document.slice(single, 2, 2)
    local merged = document.splice(single, 2, 2, replacement)
    same(document.read(merged, 0, merged.size), 'abcdef', 'same-data replacement')
    same(#merged.pieces, 1, 'adjacent contiguous pieces coalesce')
    assert(merged.pieces[1].data == single.pieces[1].data, 'splice must reuse immutable source strings')
    validate_root(result)
    validate_root(sliced)
    validate_root(merged)
  end),

  case('DOC 3: boundaries, bounds, overflow, and bounded iterator', function()
    local empty = document.empty()
    same(document.read(empty, 0, 0), '', 'empty read')
    same(document.splice(empty, 0, 0, document.empty()).size, 0, 'empty no-op splice')
    same(document.read(document.splice(empty, 0, 0, document.from_chunks({ 'X' })), 0, 1), 'X', 'insert into empty document')

    local root = document.from_chunks({ 'BC' })
    local leading = document.splice(root, 0, 0, document.from_chunks({ 'A' }))
    local trailing = document.splice(root, root.size, 0, document.from_chunks({ 'D' }))
    local overwritten = document.splice(root, 0, 2, document.from_chunks({ 'XY' }))
    local deleted = document.splice(root, 0, root.size, document.empty())
    same(document.read(leading, 0, leading.size), 'ABC', 'leading insertion')
    same(document.read(trailing, 0, trailing.size), 'BCD', 'trailing insertion')
    same(document.read(overwritten, 0, overwritten.size), 'XY', 'same-length overwrite')
    same(deleted.size, 0, 'full deletion')

    fails(function() document.read(root, -1, 0) end, 'negative read offset')
    fails(function() document.read(root, 0, -1) end, 'negative read length')
    fails(function() document.read(root, 3, 0) end, 'read past end')
    fails(function() document.read(root, 1, 2) end, 'read range past end')
    fails(function() document.slice(root, 0, 1.5) end, 'fractional slice length')
    fails(function() document.splice(root, 3, 0, document.empty()) end, 'splice past end')
    fails(function() document.splice(root, 1, 2, document.empty()) end, 'splice removal past end')
    fails(function() document.iter(root, 0, 1, 0) end, 'zero iterator chunk')
    fails(function() document.iter(root, 0, 1, -1) end, 'negative iterator chunk')
    fails(function() document.iter(root, 0, 1.25, 1) end, 'fractional iterator length')
    fails(function() document.read(root, 9007199254740992, 0) end, 'unsafe read offset')

    local max_safe = 9007199254740991
    local enormous = { pieces = {}, ends = {}, size = max_safe }
    fails(function() document.splice(root, 0, 0, enormous) end, 'splice size overflow')

    local payload = string.rep('q', 150000)
    local long_root = document.from_chunks({ payload:sub(1, 70000), payload:sub(70001) })
    local iterator = document.iter(long_root, 0, long_root.size, 1000000)
    local chunks, count = {}, 0
    while true do
      local chunk = iterator()
      if chunk == nil then break end
      assert(#chunk > 0 and #chunk <= 64 * 1024, 'iterator chunks must be at most 64 KiB')
      count = count + 1
      chunks[count] = chunk
    end
    same(table.concat(chunks), payload, 'bounded iterator reconstruction')
    same(count, 4, 'bounded iterator chunk count')
    local small_iterator = document.iter(long_root, 5, 41, 7)
    local small_chunks = {}
    for chunk in small_iterator do
      assert(#chunk <= 7, 'iterator must honor a smaller requested limit')
      small_chunks[#small_chunks + 1] = chunk
    end
    same(table.concat(small_chunks), payload:sub(6, 46), 'small iterator range')
    validate_root(leading)
    validate_root(trailing)
    validate_root(overwritten)
    validate_root(long_root)
  end),

  case('DOC 4: deterministic 500-edit string oracle', function()
    local state = 123456789
    local function random(limit)
      state = (state * 48271) % 2147483647
      return state % limit
    end
    local function random_bytes(length)
      local parts = {}
      for i = 1, length do
        parts[i] = string.char(random(256))
      end
      return table.concat(parts)
    end

    local oracle = string.char(0, 65, 255, 13, 10)
    local root = document.from_chunks({ oracle:sub(1, 2), oracle:sub(3) })
    local full_replacement = string.char(250, 251, 252)
    local replaced = document.splice(root, 0, root.size, document.from_chunks({ full_replacement }))
    same(document.read(replaced, 0, replaced.size), full_replacement, 'full-file replacement')
    same(document.read(root, 0, root.size), oracle, 'full-file replacement preserves old root')
    root, oracle = replaced, full_replacement
    for step = 1, 500 do
      local before_root, before_oracle = root, oracle
      local before_pieces, before_ends = before_root.pieces, before_root.ends
      local old_piece_state = {}
      for i, piece in ipairs(before_root.pieces) do
        old_piece_state[i] = { piece = piece, data = piece.data, start = piece.start, len = piece.len, ending = before_root.ends[i] }
      end

      local start = random(#oracle + 1)
      local remove_len = random(#oracle - start + 1)
      if step % 37 == 0 then
        start, remove_len = 0, #oracle
      end
      local insert_len = step % 11 == 0 and 0 or random(10)
      local inserted = random_bytes(insert_len)
      local insert_root = document.from_chunks({ inserted:sub(1, math.floor(insert_len / 2)), inserted:sub(math.floor(insert_len / 2) + 1) })
      local next_root = document.splice(root, start, remove_len, insert_root)
      local next_oracle = oracle:sub(1, start) .. inserted .. oracle:sub(start + remove_len + 1)

      same(document.read(next_root, 0, next_root.size), next_oracle, 'edit ' .. step .. ' full content')
      same(next_root.size, #next_oracle, 'edit ' .. step .. ' size')
      same(document.equal(next_root, document.from_chunks({ next_oracle })), true, 'edit ' .. step .. ' equality')
      validate_root(next_root)
      assert(before_root.pieces == before_pieces and before_root.ends == before_ends, 'edit ' .. step .. ' changed an old root array')
      same(before_root.size, #before_oracle, 'edit ' .. step .. ' old root size')
      same(document.read(before_root, 0, before_root.size), before_oracle, 'edit ' .. step .. ' old root bytes')
      for i, saved in ipairs(old_piece_state) do
        assert(before_root.pieces[i] == saved.piece, 'edit ' .. step .. ' replaced an old piece')
        assert(saved.piece.data == saved.data and saved.piece.start == saved.start and saved.piece.len == saved.len, 'edit ' .. step .. ' modified an old piece')
        same(before_root.ends[i], saved.ending, 'edit ' .. step .. ' old piece end')
      end

      local read_start = random(#next_oracle + 1)
      local read_len = random(#next_oracle - read_start + 1)
      same(document.read(next_root, read_start, read_len), next_oracle:sub(read_start + 1, read_start + read_len), 'edit ' .. step .. ' random read')
      if step % 25 == 0 then
        local pieces = {}
        for chunk in document.iter(next_root, 0, next_root.size, 19) do
          pieces[#pieces + 1] = chunk
        end
        same(table.concat(pieces), next_oracle, 'edit ' .. step .. ' iteration')
      end

      root, oracle = next_root, next_oracle
    end
  end),

  case('DOC 5: dirty runs compare offsets to saved baseline', function()
    local saved = document.from_chunks({ string.char(1, 2), string.char(3) })
    local changed = document.splice(saved, 1, 1, document.from_chunks({ string.char(255) }))
    same_runs(document.dirty_runs(changed, saved, 0, changed.size), { { 1, 2 } }, 'single-byte replacement')

    local restored = document.splice(changed, 1, 1, document.from_chunks({ string.char(2) }))
    same_runs(document.dirty_runs(restored, saved, 0, restored.size), {}, 'reverted byte')
    same(document.equal(restored, saved), true, 'restored logical content')

    local inserted = document.splice(saved, 1, 0, document.from_chunks({ string.char(9) }))
    same(document.read(inserted, 0, inserted.size), string.char(1, 9, 2, 3), 'inserted bytes')
    same_runs(document.dirty_runs(inserted, saved, 0, inserted.size), { { 1, 4 } }, 'offset-baseline insertion')
    same_runs(document.dirty_runs(inserted, saved, 0, 1), {}, 'clean prefix range')
    same_runs(document.dirty_runs(inserted, saved, 1, 2), { { 1, 3 } }, 'dirty viewport range')
    same_runs(document.dirty_runs(inserted, saved, inserted.size, 0), {}, 'empty dirty range')

    local shorter = document.splice(saved, 1, 2, document.empty())
    same_runs(document.dirty_runs(shorter, saved, 0, shorter.size), {}, 'shorter document has no dirty existing offsets')
    local longer = document.splice(saved, saved.size, 0, document.from_chunks({ string.char(4, 5) }))
    same_runs(document.dirty_runs(longer, saved, 0, longer.size), { { 3, 5 } }, 'tail beyond saved baseline')
  end),
}
