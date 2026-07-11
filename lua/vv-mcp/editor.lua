---读取 Neovim 当前编辑状态，不修改 buffer、窗口或磁盘文件
local Normalize = require('vv-mcp.lsp.normalize')

local M = {}

local function character_from_byte(line, byte_index)
  return vim.str_utfindex(line, 'utf-32', byte_index, false) + 1
end

local function selection_end(line, byte_column)
  local character_index = vim.str_utfindex(line, 'utf-32', byte_column - 1, false)
  return {
    byte_index = vim.str_byteindex(line, 'utf-32', character_index + 1, false),
    character = character_index + 2,
  }
end

local function error_result(code, message)
  return { error = { code = code, message = message } }
end

local function lsp_clients(bufnr)
  local seen = {}
  local names = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if not seen[client.name] then
      seen[client.name] = true
      names[#names + 1] = client.name
    end
  end
  table.sort(names)
  return names
end

local function buffer_info(bufnr, current, visible)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return {
    bufferId = bufnr,
    path = name ~= '' and Normalize.wire_path(vim.fs.normalize(name)) or nil,
    current = bufnr == current,
    visible = visible[bufnr] == true,
    listed = vim.bo[bufnr].buflisted,
    modifiable = vim.bo[bufnr].modifiable,
    modified = vim.bo[bufnr].modified,
    readonly = vim.bo[bufnr].readonly,
    buftype = vim.bo[bufnr].buftype,
    filetype = vim.bo[bufnr].filetype,
    lineCount = vim.api.nvim_buf_line_count(bufnr),
    lspClients = lsp_clients(bufnr),
  }
end

local function current_context()
  local bufnr = vim.api.nvim_get_current_buf()
  local window = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(window)
  local cursor_line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ''
  local info = buffer_info(bufnr, bufnr, { [bufnr] = true })
  info.cursor = { line = cursor[1], character = character_from_byte(cursor_line, cursor[2]) }
  info.mode = vim.api.nvim_get_mode().mode
  info.cwd = Normalize.wire_path(vim.fs.normalize(vim.fn.getcwd()))
  info.windowId = window
  info.tabpageId = vim.api.nvim_get_current_tabpage()
  return { operation = 'current_context', context = info }
end

local function is_editable_file_buffer(bufnr)
  return vim.bo[bufnr].buftype == ''
    and vim.bo[bufnr].modifiable
    and vim.api.nvim_buf_get_name(bufnr) ~= ''
end

local function list_buffers(params)
  local current = vim.api.nvim_get_current_buf()
  local visible = {}
  for _, window in ipairs(vim.api.nvim_list_wins()) do
    visible[vim.api.nvim_win_get_buf(window)] = true
  end
  local buffers = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr)
        and (params.includeSpecial == true or is_editable_file_buffer(bufnr)) then
      buffers[#buffers + 1] = buffer_info(bufnr, current, visible)
    end
  end
  table.sort(buffers, function(left, right)
    if left.current ~= right.current then return left.current end
    if left.visible ~= right.visible then return left.visible end
    return left.bufferId < right.bufferId
  end)
  return { operation = 'list_buffers', buffers = buffers }
end

local function canonical_path(path)
  return vim.fn.resolve(vim.fs.normalize(path))
end

local function loaded_buffer(path)
  local target = canonical_path(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.api.nvim_buf_is_loaded(bufnr)
        and name ~= '' and canonical_path(name) == target then
      return bufnr
    end
  end
end

local function read_buffer(params)
  if type(params.uri) ~= 'string' or params.uri == '' then
    return error_result('invalid_uri', 'uri is required for read_buffer')
  end
  local path = Normalize.input_path(params.uri)
  local bufnr = loaded_buffer(path)
  if not bufnr then
    return error_result('buffer_not_loaded', 'The requested file is not loaded in this Neovim instance')
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = params.startLine or 1
  local end_line = params.endLine or line_count
  local max_lines = params.maxLines or 200
  if start_line < 1 or end_line < 1 then
    return error_result('invalid_range', 'startLine and endLine must form a valid 1-based range')
  end
  if max_lines < 1 then return error_result('invalid_max_lines', 'maxLines must be positive') end
  if start_line > line_count then
    return error_result('range_out_of_bounds', 'startLine exceeds the buffer line count')
  end
  if start_line > end_line then
    return error_result('invalid_range', 'startLine must not exceed endLine')
  end

  end_line = math.min(end_line, line_count)
  local requested = end_line - start_line + 1
  local shown = math.min(requested, max_lines)
  local shown_end = start_line + shown - 1
  local result = {
    operation = 'read_buffer',
    bufferId = bufnr,
    path = Normalize.wire_path(canonical_path(path)),
    modified = vim.bo[bufnr].modified,
    filetype = vim.bo[bufnr].filetype,
    lineCount = line_count,
    startLine = start_line,
    endLine = shown_end,
    lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, shown_end, false),
  }
  if shown < requested then result.truncated = { shown = shown, total = requested } end
  return result
end

local function get_selection()
  local mode = vim.api.nvim_get_mode().mode
  if mode ~= 'v' and mode ~= 'V' and mode ~= '\22' then
    return error_result('no_active_selection', 'Neovim is not in a Visual selection mode')
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local anchor = vim.fn.getpos('v')
  local cursor = vim.fn.getpos('.')
  local start_line, start_col = anchor[2], anchor[3]
  local end_line, end_col = cursor[2], cursor[3]
  if start_line > end_line or (start_line == end_line and start_col > end_col) then
    start_line, end_line = end_line, start_line
    start_col, end_col = end_col, start_col
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local start_character = character_from_byte(lines[1], start_col - 1)
  local selection_end_position = selection_end(lines[#lines], end_col)
  local end_character = selection_end_position.character
  if mode == 'v' then
    lines[#lines] = lines[#lines]:sub(1, selection_end_position.byte_index)
    lines[1] = lines[1]:sub(start_col)
  elseif mode == '\22' then
    for index, line in ipairs(lines) do
      lines[index] = line:sub(start_col, selection_end(line, end_col).byte_index)
    end
  else
    start_col = 1
    end_col = #lines[#lines] + 1
    start_character = 1
    end_character = vim.str_utfindex(lines[#lines]) + 1
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  return {
    operation = 'get_selection',
    bufferId = bufnr,
    path = name ~= '' and Normalize.wire_path(vim.fs.normalize(name)) or nil,
    mode = mode == 'V' and 'line' or (mode == '\22' and 'block' or 'character'),
    range = {
      start = { line = start_line, character = start_character },
      ['end'] = { line = end_line, character = end_character },
    },
    text = table.concat(lines, '\n'),
  }
end

---执行只读编辑器状态查询
---@param params table MCP editor 工具参数
---@return table result
function M.request(params)
  if params.operation == 'current_context' then return current_context() end
  if params.operation == 'list_buffers' then return list_buffers(params) end
  if params.operation == 'read_buffer' then return read_buffer(params) end
  if params.operation == 'get_selection' then return get_selection() end
  return error_result('unsupported_operation', 'Unsupported editor operation: ' .. tostring(params.operation))
end

return M
