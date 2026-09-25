local document = require('hexit.document')
local io_module = require('hexit.io')
local helpers = require('tests.helpers')
local uv = vim.uv

local function case(name, run)
  return { name = name, run = run }
end

local function await(start)
  local done = false
  local calls = 0
  local err, value
  local callback_on_main_loop = false
  start(function(callback_err, callback_value)
    calls = calls + 1
    if calls == 1 then
      err, value = callback_err, callback_value
      callback_on_main_loop = not vim.in_fast_event()
    end
    done = true
  end)
  assert(vim.wait(10000, function() return done end, 10), 'IO callback timed out')
  assert(calls == 1, ('IO callback called %d times'):format(calls))
  assert(callback_on_main_loop, 'IO callback must run on the main loop')
  return err, value
end

local function adapter(overrides, capture)
  local result = {
    fs_open = function(path, flags, mode, callback)
      if capture and flags == 'wx' then
        capture.temp_path = path
        capture.flags = flags
      end
      return uv.fs_open(path, flags, mode, callback)
    end,
  }
  for name, operation in pairs(overrides or {}) do
    result[name] = operation
  end
  return result
end

local function assert_error(err, operation, path)
  assert(type(err) == 'string', 'expected an IO error string')
  assert(err:find(operation, 1, true), ('error should mention %s: %s'):format(operation, err))
  assert(err:find(path, 1, true), ('error should mention path %s: %s'):format(path, err))
end

local function assert_temp_removed(path)
  assert(path, 'save did not attempt to create a temporary file')
  local stat = uv.fs_stat(path)
  assert(stat == nil, 'failed or cancelled save left temporary file ' .. path)
end

local function save_once(root, path, io)
  return await(function(callback) io.save(root, path, nil, callback) end)
end

local function is_windows()
  local uname = uv.os_uname()
  return uname.sysname:lower():find('windows', 1, true) ~= nil
end

return {
  case('IO 1: binary snapshot completes after short reads', function()
    local payload = string.char(0, 10, 13, 127, 128, 255) .. 'binary tail'
    local path = helpers.temp_file(payload, 'binary \195\188 space.bin')
    local reads = 0
    local injected = adapter({
      fs_read = function(fd, size, offset, callback)
        reads = reads + 1
        if reads == 1 then
          local short_size = math.max(1, size - 3)
          return uv.fs_read(fd, short_size, offset, callback)
        end
        return uv.fs_read(fd, size, offset, callback)
      end,
    })
    local err, root = await(function(callback) io_module.new(injected).load(path, nil, callback) end)
    assert(err == nil, err)
    assert(root and root.size == #payload, 'load returned an incomplete root')
    assert(document.read(root, 0, root.size) == payload, 'loaded snapshot changed binary bytes')
    assert(reads >= 2, 'load did not continue after the injected short read')
  end),
  case('IO 2: empty snapshots and non-regular or missing paths', function()
    local empty_path = helpers.temp_file('')
    local empty_err, empty_root = await(function(callback) io_module.load(empty_path, nil, callback) end)
    assert(empty_err == nil, empty_err)
    assert(empty_root and empty_root.size == 0 and document.read(empty_root, 0, 0) == '')

    local seed = helpers.temp_file('seed')
    local directory = vim.fs.dirname(seed)
    local directory_err, directory_root = await(function(callback)
      io_module.load(directory, nil, callback)
    end)
    assert(type(directory_err) == 'string' and directory_err:find(directory, 1, true), 'directory load must report its path')
    assert(directory_root == nil, 'directory load returned a document')

    local missing = directory .. '/missing path.bin'
    local missing_err, missing_root = await(function(callback)
      io_module.load(missing, nil, callback)
    end)
    assert_error(missing_err, 'fs_open', missing)
    assert(missing_root == nil, 'missing path load returned a document')
  end),

  case('IO 3: load fstat failure closes its descriptor once', function()
    local path = helpers.temp_file('fstat failure fixture')
    local closes = 0
    local injected = adapter({
      fs_fstat = function(_, callback) callback('EIO: injected fstat failure') end,
      fs_close = function(fd, callback)
        closes = closes + 1
        return uv.fs_close(fd, callback)
      end,
    })
    local err, root = await(function(callback) io_module.new(injected).load(path, nil, callback) end)
    assert_error(err, 'fs_fstat', path)
    assert(root == nil and closes == 1, 'fstat failure did not close exactly once')
  end),

  case('IO 4: load read failure closes its descriptor once', function()
    local path = helpers.temp_file(string.char(0, 255, 10) .. 'source')
    local closes = 0
    local injected = adapter({
      fs_read = function(_, _, _, callback) callback('EIO: injected read failure') end,
      fs_close = function(fd, callback)
        closes = closes + 1
        return uv.fs_close(fd, function(close_err) callback(close_err) end)
      end,
    })
    local err, root = await(function(callback) io_module.new(injected).load(path, nil, callback) end)
    assert_error(err, 'fs_read', path)
    assert(root == nil, 'failed load returned a root')
    assert(closes == 1, ('load closed its fd %d times'):format(closes))
    assert(helpers.read_disk(path) == string.char(0, 255, 10) .. 'source', 'load failure changed its source')
  end),

  case('IO 5: partial asynchronous writes preserve binary bytes', function()
    local expected = string.rep('A', 65535) .. string.char(0, 10, 13, 255) .. string.rep('Z', 137)
    local path = helpers.temp_file('original source')
    local capture = {}
    local writes = 0
    local injected = adapter({
      fs_write = function(fd, data, offset, callback)
        writes = writes + 1
        if writes == 1 then
          return uv.fs_write(fd, data:sub(1, 3), offset, callback)
        end
        return uv.fs_write(fd, data, offset, callback)
      end,
    }, capture)
    local root = document.from_chunks({ expected:sub(1, 100), expected:sub(101) })
    local err = save_once(root, path, io_module.new(injected))
    assert(err == nil, err)
    assert(helpers.read_disk(path) == expected, 'saved file differs from the binary snapshot')
    assert(writes > 2, 'save did not resume after a partial write')
    assert(capture.flags == 'wx', 'temporary file was not opened exclusively')
    assert(vim.fs.dirname(capture.temp_path) == vim.fs.dirname(path), 'temporary file was not a sibling of the target')
    assert_temp_removed(capture.temp_path)
  end),
  case('IO 6: exclusive temp collision preserves the existing file', function()
    local path = helpers.temp_file('original target')
    local root = document.from_chunks({ 'new target bytes' })
    local marker = 'do not replace this unrelated temp'
    local capture = {}
    local collision_path
    local open_count = 0
    local injected = adapter({
      fs_open = function(candidate, flags, mode, callback)
        if flags == 'wx' then
          open_count = open_count + 1
          capture.temp_path = candidate
          capture.flags = flags
          if open_count == 1 then
            collision_path = candidate
            local collision_fd = assert(uv.fs_open(candidate, 'w', 384))
            assert(uv.fs_write(collision_fd, marker, 0) == #marker)
            assert(uv.fs_close(collision_fd))
          end
        end
        return uv.fs_open(candidate, flags, mode, callback)
      end,
    }, capture)
    local err = save_once(root, path, io_module.new(injected))
    assert(err == nil, err)
    assert(helpers.read_disk(path) == 'new target bytes', 'save did not replace target')
    assert(open_count >= 2, 'save did not retry after a name collision')
    assert(helpers.read_disk(collision_path) == marker, 'exclusive open truncated a pre-existing file')
    assert(vim.fs.dirname(collision_path) == vim.fs.dirname(path), 'temporary file was not beside the target')
    assert_temp_removed(capture.temp_path)
    assert(uv.fs_unlink(collision_path))
  end),

  case('IO 7: save failures retain source and remove the exclusive temp', function()
    local original = string.char(0, 10, 13, 255) .. 'untouched source'
    local root = document.from_chunks({ string.char(255, 0, 13, 10) .. 'replacement bytes' })
    local failures = {
      {
        operation = 'fs_write',
        adapter = function()
          return { fs_write = function(_, _, _, callback) callback('EIO: injected write failure') end }
        end,
      },
      {
        operation = 'fs_write',
        adapter = function()
          return { fs_write = function(_, _, _, callback) callback(nil, 0) end }
        end,
      },
      {
        operation = 'fs_fsync',
        adapter = function()
          return { fs_fsync = function(_, callback) callback('EIO: injected fsync failure') end }
        end,
      },
      {
        operation = 'fs_close',
        adapter = function()
          return {
            fs_close = function(fd, callback)
              return uv.fs_close(fd, function(close_err)
                callback(close_err or 'EIO: injected close failure')
              end)
            end,
          }
        end,
      },
      {
        operation = 'fs_rename',
        adapter = function()
          return { fs_rename = function(_, _, callback) callback('EIO: injected rename failure') end }
        end,
      },
    }
    for index, fault in ipairs(failures) do
      local path = helpers.temp_file(original, 'save-fault-' .. index .. '.bin')
      local capture = {}
      local injected = adapter(fault.adapter(), capture)
      local err = save_once(root, path, io_module.new(injected))
      assert_error(err, fault.operation, path)
      assert(helpers.read_disk(path) == original, fault.operation .. ' failure corrupted source bytes')
      assert_temp_removed(capture.temp_path)
    end
  end),

  case('IO 8: empty snapshot saves as a zero-byte file', function()
    local path = helpers.temp_file('previous contents')
    local capture = {}
    local err = save_once(document.empty(), path, io_module.new(adapter(nil, capture)))
    assert(err == nil, err)
    assert(helpers.read_disk(path) == '', 'empty root did not replace target with an empty file')
    assert_temp_removed(capture.temp_path)
  end),

  case('IO 9: POSIX save retains original permission bits', function()
    -- Windows does not expose POSIX permission bits; this assertion is POSIX-only.
    if is_windows() then return end
    local path = helpers.temp_file('original')
    local capture = {}
    local expected_mode = 384 -- 0600
    assert(uv.fs_chmod(path, expected_mode))
    local err = save_once(document.from_chunks({ 'replacement' }), path, io_module.new(adapter(nil, capture)))
    assert(err == nil, err)
    local stat = assert(uv.fs_stat(path))
    assert(stat.mode % 4096 == expected_mode, ('expected mode %o, got %o'):format(expected_mode, stat.mode % 4096))
    assert(helpers.read_disk(path) == 'replacement', 'permission-preserving save changed content')
    assert_temp_removed(capture.temp_path)
  end),

  case('IO 10: cancellation closes load and removes partial save', function()
    local payload = string.rep('load bytes', 200)
    local load_path = helpers.temp_file(payload, 'cancel-load.bin')
    local load_token = {}
    local load_closes = 0
    local load_adapter = adapter({
      fs_read = function(fd, size, offset, callback)
        return uv.fs_read(fd, size, offset, function(err, data)
          load_token.cancelled = true
          callback(err, data)
        end)
      end,
      fs_close = function(fd, callback)
        load_closes = load_closes + 1
        return uv.fs_close(fd, callback)
      end,
    })
    local load_err, loaded = await(function(callback)
      io_module.new(load_adapter).load(load_path, load_token, callback)
    end)
    assert_error(load_err, 'load', load_path)
    assert(loaded == nil and load_closes == 1, 'cancelled load did not close exactly once')

    local original = string.char(0, 255) .. 'save source'
    local save_path = helpers.temp_file(original, 'cancel-save.bin')
    local save_token = {}
    local capture = {}
    local save_closes = 0
    local save_adapter = adapter({
      fs_write = function(fd, data, offset, callback)
        return uv.fs_write(fd, data, offset, function(err, count)
          save_token.cancelled = true
          callback(err, count)
        end)
      end,
      fs_close = function(fd, callback)
        save_closes = save_closes + 1
        return uv.fs_close(fd, callback)
      end,
    }, capture)
    local save_err = await(function(callback)
      io_module.new(save_adapter).save(document.from_chunks({ string.rep('X', 100) }), save_path, save_token, callback)
    end)
    assert_error(save_err, 'save', save_path)
    assert(save_closes == 1, ('cancelled save closed its fd %d times'):format(save_closes))
    assert(helpers.read_disk(save_path) == original, 'cancelled save changed source bytes')
    assert_temp_removed(capture.temp_path)
  end),
  case('IO 11: loading reports bounded binary byte progress', function()
    local size = 2 * 1024 * 1024
    local path = helpers.temp_file(string.rep(string.char(0, 255), size / 2))
    local updates = {}
    local token = {
      on_progress = function(read, total)
        assert(vim.in_fast_event() == false, 'progress changed UI from a uv callback')
        assert(total == size and read >= 0 and read <= size)
        updates[#updates + 1] = read
      end,
    }
    local err, root = await(function(callback) io_module.load(path, token, callback) end)
    assert(err == nil, err)
    assert(root.size == size)
    assert(vim.deep_equal(updates, { 0, 1024 * 1024, size }), vim.inspect(updates))
  end),
}
