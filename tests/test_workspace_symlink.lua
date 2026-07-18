local root = vim.fn.getcwd()
dofile(root .. '/tests/minimal_init.lua')

local Fs = require('vv-utils.fs')
local Instance = require('vv-mcp.instance')
local Workspace = require('vv-mcp.workspace')

local tmp = vim.fn.tempname()
Fs.mkdir_p(tmp)

-- 用可控 roots 替换实例探测，隔离 cwd/项目根，专注 symlink 边界
local current_roots = {}
local original_current = Instance.current
Instance.current = function() return { roots = current_roots } end

local function symlink(target, link)
  assert(vim.uv.fs_symlink(target, link), 'symlink failed: ' .. link .. ' -> ' .. target)
end

-- 场景 A：整个 workspace root 本身是 symlink —— 边界判定须解析后接受，apply 落到真实文件
do
  local real_ws = vim.fs.joinpath(tmp, 'a-real-ws')
  local link_ws = vim.fs.joinpath(tmp, 'a-link-ws')
  Fs.mkdir_p(real_ws)
  symlink(real_ws, link_ws)
  current_roots = { link_ws }

  Fs.write_all(vim.fs.joinpath(real_ws, 'mod.ts'), 'export const a = 1\n')

  local preview = Workspace.request({
    operation = 'rename_resource_preview',
    oldUri = vim.fs.joinpath(link_ws, 'mod.ts'),
    newUri = vim.fs.joinpath(link_ws, 'renamed.ts'),
  })
  assert(not preview.error, 'A: root-as-symlink preview should pass containment: ' .. vim.inspect(preview.error))

  local applied = Workspace.request({
    operation = 'rename_resource_apply',
    resourceRenameId = preview.resourceRenameId,
  })
  assert(applied.applied == true, 'A: apply should succeed: ' .. vim.inspect(applied))
  assert(not Fs.exists(vim.fs.joinpath(real_ws, 'mod.ts')), 'A: old real file should be gone')
  assert(Fs.exists(vim.fs.joinpath(real_ws, 'renamed.ts')), 'A: new real file should exist under the real root')
end

-- 场景 B：内部目录 symlink 越出 workspace —— 无论 old 还是 new 经它越界都必须拒绝
do
  local ws = vim.fs.joinpath(tmp, 'b-ws')
  local outside = vim.fs.joinpath(tmp, 'b-outside')
  Fs.mkdir_p(ws)
  Fs.mkdir_p(outside)
  symlink(outside, vim.fs.joinpath(ws, 'escape')) -- ws/escape -> b-outside（越界）
  current_roots = { ws }

  local secret = vim.fs.joinpath(outside, 'secret.ts')
  Fs.write_all(secret, 'top secret\n')

  -- old 经内部 symlink 指向 workspace 外
  local escape_old = Workspace.request({
    operation = 'rename_resource_preview',
    oldUri = vim.fs.joinpath(ws, 'escape/secret.ts'),
    newUri = vim.fs.joinpath(ws, 'escape/secret2.ts'),
  })
  assert(escape_old.error and escape_old.error.code == 'resource_outside_workspace',
    'B: escaping old path must be rejected: ' .. vim.inspect(escape_old))
  assert(Fs.read_all(secret) == 'top secret\n', 'B: real outside file must be untouched')
  assert(not Fs.exists(vim.fs.joinpath(outside, 'secret2.ts')), 'B: no target created outside')

  -- new 经内部 symlink 越界（old 在 workspace 内）
  local inside = vim.fs.joinpath(ws, 'inside.ts')
  Fs.write_all(inside, 'inside\n')
  local escape_new = Workspace.request({
    operation = 'rename_resource_preview',
    oldUri = inside,
    newUri = vim.fs.joinpath(ws, 'escape/leak.ts'),
  })
  assert(escape_new.error and escape_new.error.code == 'resource_outside_workspace',
    'B: escaping new path must be rejected: ' .. vim.inspect(escape_new))
  assert(not Fs.exists(vim.fs.joinpath(outside, 'leak.ts')), 'B: nothing should be created outside')
  assert(Fs.exists(inside), 'B: source must stay put after rejected rename')
end

-- 场景 C：经 symlink 打开的已改 buffer —— buffer 名是真实路径，保护须命中（本次修复的核心）
-- 复刻真实场景：root 同时包含 .trae 与 .agents 两侧，symlink 指向 workspace 内的另一处
do
  local ws = vim.fs.joinpath(tmp, 'c-ws')
  local agents = vim.fs.joinpath(ws, '.agents/skills/lark-mail')
  Fs.mkdir_p(ws)
  Fs.mkdir_p(agents)
  symlink(agents, vim.fs.joinpath(ws, 'lark-mail')) -- ws/lark-mail -> ws/.agents/.../lark-mail（仍在 root 内）
  current_roots = { ws }

  local real_file = vim.fs.joinpath(agents, 'config.ts')
  Fs.write_all(real_file, 'export const x = 1\n')

  local logical = vim.fs.joinpath(ws, 'lark-mail/config.ts')
  local buf = vim.fn.bufadd(logical)
  vim.fn.bufload(buf)
  -- 前提锁定：Neovim 打开逻辑路径后，buffer 名解析为真实路径（agents 侧）
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(buf)) == Fs.realpath(real_file),
    'C: buffer name must be the resolved real path')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'export const x = 2' }) -- 置为 modified

  local preview = Workspace.request({
    operation = 'rename_resource_preview',
    oldUri = logical,
    newUri = vim.fs.joinpath(ws, 'lark-mail/config2.ts'),
  })
  assert(preview.error and preview.error.code == 'resource_buffer_modified',
    'C: modified buffer opened via symlink must block preview: ' .. vim.inspect(preview))

  vim.api.nvim_buf_delete(buf, { force = true })
end

-- 场景 D：目标不存在（新建于尚不存在的子目录）—— 边界判定须解析最近存在祖先，不误判越界
do
  local ws = vim.fs.joinpath(tmp, 'd-ws')
  Fs.mkdir_p(ws)
  current_roots = { ws }

  local src = vim.fs.joinpath(ws, 'src.ts')
  Fs.write_all(src, 'export const d = 1\n')
  local dest = vim.fs.joinpath(ws, 'nested/deep/dest.ts') -- nested/deep 均不存在

  local preview = Workspace.request({
    operation = 'rename_resource_preview',
    oldUri = src,
    newUri = dest,
  })
  assert(not preview.error, 'D: rename into a non-existing subdir should pass containment: ' .. vim.inspect(preview.error))

  local applied = Workspace.request({
    operation = 'rename_resource_apply',
    resourceRenameId = preview.resourceRenameId,
  })
  assert(applied.applied == true, 'D: apply should succeed: ' .. vim.inspect(applied))
  assert(not Fs.exists(src), 'D: source should be gone')
  assert(Fs.exists(dest), 'D: target should be created in the new nested dir')
end

-- 场景 E：preview→apply 窗口内，target 父目录被换成越界 symlink —— apply 必须判定 stale 且零副作用
-- rename(2) 会沿中间 symlink 把文件移出 workspace，preview 固化的真实边界须在 apply 前后复检（本轮修复核心）
do
  local ws = vim.fs.joinpath(tmp, 'e-ws')
  local outside = vim.fs.joinpath(tmp, 'e-outside')
  Fs.mkdir_p(ws)
  Fs.mkdir_p(outside)
  current_roots = { ws }

  local src = vim.fs.joinpath(ws, 'mod.ts')
  Fs.write_all(src, 'export const value = 1\n')

  -- consumer 经 LSP willRename 改写 import —— 用于验证 stale apply 未落下任何 WorkspaceEdit
  local consumer = vim.fs.joinpath(ws, 'consumer.ts')
  local before_import = "import { value } from './mod'"
  local after_import = "import { value } from './parent/renamed'"
  Fs.write_all(consumer, before_import .. '\n')

  local parent = vim.fs.joinpath(ws, 'parent')
  Fs.mkdir_p(parent) -- workspace 内普通目录
  local dest = vim.fs.joinpath(parent, 'renamed.ts') -- 目标不存在

  local original_get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function()
    return {{
      name = 'fixture-lsp',
      offset_encoding = 'utf-16',
      server_capabilities = {
        workspace = { fileOperations = { willRename = {}, didRename = {} } },
      },
      request_sync = function(_, method)
        assert(method == 'workspace/willRenameFiles')
        return {
          result = {
            changes = {
              [vim.uri_from_fname(consumer)] = {{
                range = {
                  start = { line = 0, character = 0 },
                  ['end'] = { line = 0, character = #before_import },
                },
                newText = after_import,
              }},
            },
          },
        }
      end,
      notify = function() end,
      stop = function() end,
    }}
  end

  local preview = Workspace.request({
    operation = 'rename_resource_preview',
    oldUri = src,
    newUri = dest,
  })
  assert(not preview.error, 'E: preview into a workspace-internal dir should pass: ' .. vim.inspect(preview.error))
  assert(preview.editsCount == 1, 'E: preview should stage the LSP import edit')

  -- 事务窗口内把 target 父目录替换成指向 workspace 外的 symlink（先 rm 原目录再建链）
  Fs.delete(parent)
  symlink(outside, parent) -- ws/parent -> e-outside（越界），outside/renamed.ts 尚不存在

  local applied = Workspace.request({
    operation = 'rename_resource_apply',
    resourceRenameId = preview.resourceRenameId,
  })
  assert(applied.error and applied.error.code == 'resource_rename_stale',
    'E: mid-transaction symlink redirect must be rejected as stale: ' .. vim.inspect(applied))

  assert(Fs.exists(src), 'E: source must stay put after a rejected apply')
  assert(not Fs.exists(vim.fs.joinpath(outside, 'renamed.ts')), 'E: nothing may be created outside the workspace')
  assert(Fs.read_all(consumer) == before_import .. '\n', 'E: no WorkspaceEdit may leak into the consumer import')

  vim.lsp.get_clients = original_get_clients
end

Instance.current = original_current
Fs.delete(tmp)

print('vv-mcp workspace symlink boundary test: ok')
