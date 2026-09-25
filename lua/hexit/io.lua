local uv = vim.uv
local document = require('hexit.document')

local M = {}
local MAX_CHUNK = 1024 * 1024
local WRITE_CHUNK = 64 * 1024
local MAX_SAFE_INTEGER = 9007199254740991
local temp_counter = 0
local pid = uv.os_getpid and uv.os_getpid() or 0

local function is_cancelled(token)
  return token ~= nil and token.cancelled == true
end

local function quote(value)
  return string.format('%q', tostring(value))
end

local function error_for(operation, path, detail, temp_path)
  local message = 'hexit: ' .. operation .. ' ' .. quote(path)
  if temp_path ~= nil then
    message = message .. ' (temporary ' .. quote(temp_path) .. ')'
  end
  if detail ~= nil then
    message = message .. ': ' .. tostring(detail)
  end
  return message
end

local function is_regular(stat)
  if type(stat) ~= 'table' then
    return false
  end
  if type(stat.type) == 'string' then
    return stat.type == 'file'
  end
  local mode = stat.mode
  return type(mode) == 'number' and math.floor(mode / 4096) % 16 == 8
end

local function valid_size(size)
  return type(size) == 'number' and size >= 0 and size <= MAX_SAFE_INTEGER and size % 1 == 0
end

local function is_windows()
  if jit and jit.os == 'Windows' then
    return true
  end
  local uname = uv.os_uname and uv.os_uname()
  return uname ~= nil and uname.sysname:lower():find('windows', 1, true) ~= nil
end

local function is_exists_error(err)
  return err == 'EEXIST' or (type(err) == 'string' and err:find('EEXIST', 1, true) ~= nil)
end

local function is_missing_error(err)
  return err == 'ENOENT' or (type(err) == 'string' and err:find('ENOENT', 1, true) ~= nil)
end

local function sibling_temp_path(path)
  temp_counter = temp_counter + 1
  local directory = path:match('^(.*[/\\])') or ''
  return directory .. '.hexit-tmp-' .. tostring(pid) .. '-' .. tostring(temp_counter)
end

local function uv_call(adapter, name, a, b, c, callback)
  local operation = adapter[name] or uv[name]
  if type(operation) ~= 'function' then
    callback('uv.' .. name .. ' is unavailable')
    return
  end

  local called = false
  local in_callback = false
  local function done(...)
    if called then
      return
    end
    called = true
    in_callback = true
    callback(...)
    in_callback = false
  end

  local ok, err
  if c ~= nil then
    ok, err = pcall(operation, a, b, c, done)
  elseif b ~= nil then
    ok, err = pcall(operation, a, b, done)
  elseif a ~= nil then
    ok, err = pcall(operation, a, done)
  else
    ok, err = pcall(operation, done)
  end
  if not ok then
    if in_callback then
      error(err, 0)
    end
    done(tostring(err))
  end

end
local function scheduled_callback(token, callback, err, value, committed, cancellation_error)
  vim.schedule(function()
    if is_cancelled(token) and err == nil and not committed then
      err = cancellation_error or 'hexit: operation canceled'
      value = nil
    end
    callback(err, value)
  end)
end

function M.new(adapter)
  adapter = adapter or {}
  local io = {}

  function io.load(path, token, callback)
    local completed = false
    local stopping = false
    local fd
    local chunks = {}
    local size
    local position = 0
    local last_reported = 0
    local function report_progress(force)
      if not token or not token.on_progress then return end
      if not force and position - last_reported < MAX_CHUNK then return end
      last_reported = position
      local read, total = position, size
      vim.schedule(function()
        if not is_cancelled(token) then token.on_progress(read, total) end
      end)
    end

    local function complete(err, value)
      if completed then
        return
      end
      completed = true
      scheduled_callback(token, callback, err, value, false, error_for('load', path, 'cancelled'))
    end

    local function fail(err)
      if stopping or completed then
        return
      end
      stopping = true
      local current_fd = fd
      fd = nil
      if current_fd == nil then
        complete(err)
        return
      end
      uv_call(adapter, 'fs_close', current_fd, nil, nil, function(close_err)
        if close_err then
          err = err .. '; ' .. error_for('fs_close', path, close_err)
        end
        complete(err)
      end)
    end

    local function cancelled_error()
      return error_for('load', path, 'cancelled')
    end

    local function check_cancel()
      if is_cancelled(token) then
        fail(cancelled_error())
        return true
      end
      return false
    end

    local function finish_read()
      if check_cancel() then
        return
      end
      uv_call(adapter, 'fs_fstat', fd, nil, nil, function(err, stat)
        if check_cancel() then
          return
        end
        if err then
          fail(error_for('fs_fstat', path, err))
          return
        end
        if not is_regular(stat) then
          fail(error_for('fs_fstat', path, 'file is no longer a regular file'))
          return
        end
        if not valid_size(stat.size) or stat.size ~= size or position ~= size then
          fail(error_for('fs_read', path, 'file size changed while reading (expected ' .. tostring(size) .. ', read ' .. tostring(position) .. ', current ' .. tostring(stat.size) .. ')'))
          return
        end

        stopping = true
        local current_fd = fd
        fd = nil
        uv_call(adapter, 'fs_close', current_fd, nil, nil, function(close_err)
          local was_cancelled = is_cancelled(token)
          if close_err then
            complete(error_for('fs_close', path, close_err))
            return
          end
          if was_cancelled then
            complete(cancelled_error())
            return
          end
          local ok, root = pcall(document.from_chunks, chunks)
          if not ok then
            complete(error_for('document.from_chunks', path, root))
            return
          end
          if root.size ~= size then
            complete(error_for('load', path, 'snapshot size mismatch (expected ' .. tostring(size) .. ', got ' .. tostring(root.size) .. ')'))
            return
          end
          complete(nil, root)
        end)
      end)
    end

    local read_next
    read_next = function()
      if stopping or completed or check_cancel() then
        return
      end
      if position == size then
        finish_read()
        return
      end
      local requested = math.min(MAX_CHUNK, size - position)
      local offset = position
      uv_call(adapter, 'fs_read', fd, requested, offset, function(err, data)
        if check_cancel() then
          return
        end
        if err then
          fail(error_for('fs_read', path, err))
          return
        end
        if type(data) ~= 'string' then
          fail(error_for('fs_read', path, 'expected binary string result'))
          return
        end
        local received = #data
        if received == 0 then
          fail(error_for('fs_read', path, 'unexpected EOF (read ' .. tostring(position) .. ' of ' .. tostring(size) .. ' bytes)'))
          return
        end
        if received > requested then
          fail(error_for('fs_read', path, 'read returned more bytes than requested'))
          return
        end
        chunks[#chunks + 1] = data
        position = position + received
        report_progress(position == size)
        read_next()
      end)
    end

    if check_cancel() then
      return
    end
    uv_call(adapter, 'fs_open', path, 'r', 438, function(err, opened_fd)
      if opened_fd ~= nil then
        fd = opened_fd
      end
      if check_cancel() then
        return
      end
      if err then
        fail(error_for('fs_open', path, err))
        return
      end
      if fd == nil then
        fail(error_for('fs_open', path, 'no file descriptor returned'))
        return
      end
      uv_call(adapter, 'fs_fstat', fd, nil, nil, function(stat_err, stat)
        if check_cancel() then
          return
        end
        if stat_err then
          fail(error_for('fs_fstat', path, stat_err))
          return
        end
        if not is_regular(stat) then
          fail(error_for('fs_fstat', path, 'not a regular file'))
          return
        end
        if not valid_size(stat.size) then
          fail(error_for('fs_fstat', path, 'invalid file size'))
          return
        end
        size = stat.size
        report_progress(true)
        read_next()
      end)
    end)
  end

  function io.save(root, path, token, callback)
    local completed = false
    local stopping = false
    local fd
    local temp_path
    local owned_temp = false
    local position = 0
    local pending_chunk
    local pending_offset = 0
    local committed = false

    local function complete(err, value, was_committed)
      if completed then
        return
      end
      completed = true
      scheduled_callback(token, callback, err, value, was_committed == true, error_for('save', path, 'cancelled', temp_path))
    end

    local function cancel_error()
      return error_for('save', path, 'cancelled', temp_path)
    end

    local function append_cleanup_error(err, operation, detail)
      local cleanup_err = error_for(operation, path, detail, temp_path)
      if err == nil then
        return cleanup_err
      end
      return err .. '; ' .. cleanup_err
    end

    local cleanup
    cleanup = function(err)
      if stopping or completed then
        return
      end
      stopping = true
      local function unlink_temp(current_err)
        if not owned_temp or temp_path == nil then
          complete(current_err)
          return
        end
        local path_to_unlink = temp_path
        owned_temp = false
        temp_path = nil
        uv_call(adapter, 'fs_unlink', path_to_unlink, nil, nil, function(unlink_err)
          local _cancelled = is_cancelled(token)
          if unlink_err and not is_missing_error(unlink_err) then
            current_err = current_err .. '; ' .. error_for('fs_unlink', path, unlink_err, path_to_unlink)
          end
          if _cancelled and current_err == nil then
            current_err = error_for('save', path, 'cancelled', path_to_unlink)
          end
          complete(current_err)
        end)
      end

      local current_fd = fd
      fd = nil
      if current_fd == nil then
        unlink_temp(err)
        return
      end
      uv_call(adapter, 'fs_close', current_fd, nil, nil, function(close_err)
        if is_cancelled(token) and err == nil then
          err = cancel_error()
        end
        if close_err then
          err = append_cleanup_error(err, 'fs_close', close_err)
        end
        unlink_temp(err)
      end)
    end

    local function fail(err)
      cleanup(err)
    end

    local function check_cancel()
      if is_cancelled(token) then
        fail(cancel_error())
        return true
      end
      return false
    end

    if type(root) ~= 'table' or not valid_size(root.size) then
      complete(error_for('save', path, 'invalid document root'))
      return
    end
    local ok_iter, iterator = pcall(document.iter, root, 0, root.size, WRITE_CHUNK)
    if not ok_iter or type(iterator) ~= 'function' then
      complete(error_for('document.iter', path, ok_iter and 'invalid iterator' or iterator))
      return
    end

    local source_mode
    local after_temp_open
    local write_next_chunk
    local function next_temp()
      if check_cancel() then
        return
      end
      local attempts = 0
      local function try_open()
        if check_cancel() then
          return
        end
        attempts = attempts + 1
        if attempts > 128 then
          fail(error_for('fs_open', path, 'unable to allocate a unique temporary file'))
          return
        end
        local candidate = sibling_temp_path(path)
        uv_call(adapter, 'fs_open', candidate, 'wx', source_mode or 438, function(err, opened_fd)
          if err and is_exists_error(err) and opened_fd == nil then
            try_open()
            return
          end
          if opened_fd ~= nil then
            fd = opened_fd
            temp_path = candidate
            owned_temp = true
          end
          if check_cancel() then
            return
          end
          if err then
            fail(error_for('fs_open', path, err, candidate))
            return
          end
          if fd == nil then
            fail(error_for('fs_open', path, 'no file descriptor returned', candidate))
            return
          end
          after_temp_open()
        end)
      end
      try_open()
    end

    after_temp_open = function()
      if check_cancel() then
        return
      end
      write_next_chunk()
    end

    local function rename_temp()
      if check_cancel() then
        return
      end
      local old_path = temp_path
      local current_fd = fd
      if current_fd ~= nil then
        fail(error_for('fs_rename', path, 'temporary file remained open', old_path))
        return
      end
      uv_call(adapter, 'fs_rename', old_path, path, nil, function(err)
        local was_cancelled = is_cancelled(token)
        if err then
          fail(error_for('fs_rename', path, err, old_path))
          return
        end
        temp_path = nil
        owned_temp = false
        committed = true
        stopping = true
        -- The rename is the commit point; cancellation cannot undo it.
        complete(nil, nil, committed or was_cancelled)
      end)
    end

    local function close_then_rename()
      if check_cancel() then
        return
      end
      local current_fd = fd
      fd = nil
      uv_call(adapter, 'fs_close', current_fd, nil, nil, function(err)
        if check_cancel() then
          return
        end
        if err then
          fail(error_for('fs_close', path, err, temp_path))
          return
        end
        rename_temp()
      end)
    end

    local fsync_temp
    local function apply_permissions_then_fsync()
      if check_cancel() then
        return
      end
      if is_windows() then
        fsync_temp()
        return
      end
      uv_call(adapter, 'fs_chmod', temp_path, source_mode, nil, function(chmod_err)
        if check_cancel() then
          return
        end
        if chmod_err then
          fail(error_for('fs_chmod', path, chmod_err, temp_path))
          return
        end
        fsync_temp()
      end)
    end
    fsync_temp = function()
      if check_cancel() then
        return
      end
      uv_call(adapter, 'fs_fsync', fd, nil, nil, function(err)
        if check_cancel() then
          return
        end
        if err then
          fail(error_for('fs_fsync', path, err, temp_path))
          return
        end
        close_then_rename()
      end)
    end

    local function write_chunk_part()
      if check_cancel() then
        return
      end
      local remaining = #pending_chunk - pending_offset
      if remaining <= 0 then
        pending_chunk = nil
        pending_offset = 0
        write_next_chunk()
        return
      end
      local data = pending_offset == 0 and pending_chunk or pending_chunk:sub(pending_offset + 1)
      local write_at = position
      uv_call(adapter, 'fs_write', fd, data, write_at, function(err, bytes_written)
        if check_cancel() then
          return
        end
        if err then
          fail(error_for('fs_write', path, err, temp_path))
          return
        end
        if type(bytes_written) ~= 'number' or bytes_written % 1 ~= 0 or bytes_written < 0 or bytes_written > #data then
          fail(error_for('fs_write', path, 'invalid byte count ' .. tostring(bytes_written), temp_path))
          return
        end
        if bytes_written == 0 then
          fail(error_for('fs_write', path, 'write returned 0 bytes', temp_path))
          return
        end
        position = position + bytes_written
        pending_offset = pending_offset + bytes_written
        if pending_offset < #pending_chunk then
          write_chunk_part()
        else
          pending_chunk = nil
          pending_offset = 0
          write_next_chunk()
        end
      end)
    end

    write_next_chunk = function()
      if check_cancel() then
        return
      end
      if position == root.size then
        local ok_next, chunk = pcall(iterator)
        if not ok_next then
          fail(error_for('document.iter', path, chunk, temp_path))
          return
        end
        if chunk ~= nil then
          fail(error_for('document.iter', path, 'yielded data beyond document size', temp_path))
          return
        end
        apply_permissions_then_fsync()
        return
      end
      local ok_next, chunk = pcall(iterator)
      if not ok_next then
        fail(error_for('document.iter', path, chunk, temp_path))
        return
      end
      if type(chunk) ~= 'string' or #chunk == 0 then
        fail(error_for('document.iter', path, 'ended before document size', temp_path))
        return
      end
      if #chunk > WRITE_CHUNK or #chunk > root.size - position then
        fail(error_for('document.iter', path, 'yielded an invalid chunk size', temp_path))
        return
      end
      pending_chunk = chunk
      pending_offset = 0
      write_chunk_part()
    end


    if check_cancel() then
      return
    end
    uv_call(adapter, 'fs_stat', path, nil, nil, function(err, stat)
      if check_cancel() then
        return
      end
      if err then
        fail(error_for('fs_stat', path, err))
        return
      end
      if not is_regular(stat) then
        fail(error_for('fs_stat', path, 'not a regular file'))
        return
      end
      source_mode = type(stat.mode) == 'number' and math.floor(stat.mode) % 4096 or 438
      next_temp()
    end)
  end

  return io
end

local default = M.new()
M.load = default.load
M.save = default.save

return M
