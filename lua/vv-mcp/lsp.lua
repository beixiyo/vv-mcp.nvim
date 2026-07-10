local M = {}

local operations = {
  definition = 'textDocument/definition',
  declaration = 'textDocument/declaration',
  implementation = 'textDocument/implementation',
  references = 'textDocument/references',
}

local function wire_path(path)
  return path:gsub('\\', '/')
end

local function normalize_result(value)
  if type(value) ~= 'table' then return value end

  if value.uri then value.uri = wire_path(vim.uri_to_fname(value.uri)) end
  if value.targetUri then value.targetUri = wire_path(vim.uri_to_fname(value.targetUri)) end

  for key, child in pairs(value) do
    if key == 'line' or key == 'character' then
      value[key] = child + 1
    elseif type(child) == 'table' then
      normalize_result(child)
    end
  end

  return value
end

local function wait_for_clients(bufnr, timeout_ms)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients > 0 then return clients end

  vim.wait(timeout_ms, function()
    clients = vim.lsp.get_clients({ bufnr = bufnr })
    return #clients > 0
  end, 20)

  return clients
end

---@param params table
---@return table
function M.request(params)
  local method = operations[params.operation]
  if not method then
    return { error = { code = 'unsupported_operation', message = 'Unsupported LSP operation: ' .. tostring(params.operation) } }
  end
  if type(params.line) ~= 'number' or params.line < 1
      or type(params.character) ~= 'number' or params.character < 1 then
    return { error = { code = 'invalid_position', message = 'line and character must be 1-based positive integers' } }
  end

  local input = params.uri
  local path = vim.fs.normalize(input:sub(1, 7) == 'file://' and vim.uri_to_fname(input) or input)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  local timeout_ms = type(params.timeoutMs) == 'number' and params.timeoutMs or 3000
  local clients = wait_for_clients(bufnr, timeout_ms)
  if #clients == 0 then
    return { error = { code = 'no_lsp', message = 'No LSP client attached to buffer', path = wire_path(path) } }
  end

  local results = {}
  for _, client in ipairs(clients) do
    if client:supports_method(method, bufnr) then
      local request_params = {
        textDocument = { uri = vim.uri_from_bufnr(bufnr) },
        position = { line = params.line - 1, character = params.character - 1 },
      }
      if params.operation == 'references' then
        request_params.context = { includeDeclaration = true }
      end

      local response, error = client:request_sync(method, request_params, timeout_ms, bufnr)
      results[#results + 1] = {
        client = client.name,
        result = response and normalize_result(response.result) or nil,
        error = error and tostring(error) or nil,
      }
    end
  end

  if #results == 0 then
    return {
      error = {
        code = 'capability_unsupported',
        message = 'Attached LSP clients do not support ' .. method,
        clients = vim.tbl_map(function(client) return client.name end, clients),
      },
    }
  end

  return {
    operation = params.operation,
    path = wire_path(path),
    line = params.line,
    character = params.character,
    results = results,
  }
end

return M
