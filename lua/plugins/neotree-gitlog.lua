local cache = {}
local pending = {}
local queue = {}
local running = 0
local MAX_CONCURRENCY = 8
local roots = {}

local function get_git_root(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  if roots[dir] ~= nil then
    return roots[dir]
  end
  local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 or not out[1] then
    roots[dir] = false
    return nil
  end
  roots[dir] = out[1]
  return out[1]
end

local refresh_scheduled = false
local function schedule_refresh()
  if refresh_scheduled then
    return
  end
  refresh_scheduled = true
  vim.defer_fn(function()
    refresh_scheduled = false
    pcall(function()
      require("neo-tree.sources.manager").refresh("filesystem")
    end)
  end, 200)
end

local function run_next()
  while running < MAX_CONCURRENCY do
    local job = table.remove(queue, 1)
    if not job then
      return
    end
    running = running + 1
    local ok = pcall(vim.system,
      { "git", "-C", job.root, "log", "-1", "--format=%H%x09%cr%x09%an%x09%s", "--", job.path },
      { text = true },
      vim.schedule_wrap(function(obj)
        pcall(function()
          pending[job.path] = nil
          if not obj or obj.code ~= 0 or not obj.stdout or obj.stdout == "" then
            cache[job.path] = { hash = "", time = "", author = "", msg = "" }
          else
            local line = obj.stdout:gsub("\n$", "")
            local hash, time, author, msg = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
            cache[job.path] = { hash = hash or "", time = time or "", author = author or "", msg = msg or "" }
          end
        end)
        running = running - 1
        schedule_refresh()
        run_next()
      end)
    )
    if not ok then
      pending[job.path] = nil
      running = running - 1
      cache[job.path] = { hash = "", time = "", author = "", msg = "" }
    end
  end
end

local function fetch(path, root)
  if cache[path] ~= nil or pending[path] then
    return
  end
  pending[path] = true
  table.insert(queue, { path = path, root = root })
  run_next()
end

-- 按显示宽度截断或右侧补空格到固定宽度
local function fit(s, w)
  s = tostring(s or "")
  if w <= 0 then
    return ""
  end
  local dw = vim.fn.strdisplaywidth(s)
  if dw <= w then
    return s .. string.rep(" ", w - dw)
  end
  local result = {}
  local cur = 0
  local chars = vim.fn.split(s, "\\zs")
  for _, ch in ipairs(chars) do
    local cw = vim.fn.strdisplaywidth(ch)
    if cur + cw > w - 1 then
      break
    end
    table.insert(result, ch)
    cur = cur + cw
  end
  table.insert(result, "…")
  cur = cur + 1
  if cur < w then
    table.insert(result, string.rep(" ", w - cur))
  end
  return table.concat(result, "")
end

-- 自定义灰色高亮组（避免依赖 colorscheme 的 Comment 颜色）
local function ensure_highlights()
  if vim.fn.hlexists("NeoTreeGitLogMsg") == 0 then
    vim.api.nvim_set_hl(0, "NeoTreeGitLogMsg", { fg = "#808080", default = true })
  end
  if vim.fn.hlexists("NeoTreeGitLogAuthor") == 0 then
    vim.api.nvim_set_hl(0, "NeoTreeGitLogAuthor", { fg = "#a0a0a0", default = true })
  end
end

local function last_commit(config, node, _)
  local ok, result = pcall(function()
    if not node or type(node) ~= "table" then
      return {}
    end
    local path = node.path
    if type(path) ~= "string" or path == "" then
      return {}
    end
    local root = get_git_root(path)
    if not root then
      return {}
    end

    local entry = cache[path]
    if entry == nil then
      fetch(path, root)
      return {}
    end

    local cfg = config or {}
    local tw = cfg.time_width or 14
    local aw = cfg.author_width or 10
    local mw = cfg.msg_width or 50

    if not entry.time or entry.time == "" then
      return {
        { text = fit("—", tw), highlight = "NeoTreeGitLogMsg" },
        { text = "  ", highlight = "NeoTreeGitLogMsg" },
        { text = fit("", aw), highlight = "NeoTreeGitLogMsg" },
        { text = "  ", highlight = "NeoTreeGitLogMsg" },
        { text = fit("uncommitted", mw), highlight = "NeoTreeGitLogMsg" },
      }
    end

    return {
      { text = fit(entry.time or "", tw), highlight = "NeoTreeGitUntracked" },
      { text = "  ", highlight = "NeoTreeGitLogMsg" },
      { text = fit(entry.author or "", aw), highlight = "NeoTreeGitLogAuthor" },
      { text = "  ", highlight = "NeoTreeGitLogMsg" },
      { text = fit(entry.msg or "", mw), highlight = "NeoTreeGitLogMsg" },
    }
  end)
  if not ok then
    return {}
  end
  return result or {}
end

local function build_dir_renderer()
  return {
    { "indent" },
    { "icon" },
    { "current_filter" },
    {
      "container",
      content = {
        { "name", zindex = 10 },
        { "symlink_target", zindex = 10, highlight = "NeoTreeSymbolicLinkTarget" },
        { "clipboard", zindex = 10 },
        { "diagnostics", errors_only = true, zindex = 20, align = "right", hide_when_expanded = true },
        { "git_status", zindex = 10, align = "right", hide_when_expanded = true },
        { "last_commit", zindex = 15, align = "right", required_width = 110, hide_when_expanded = true },
      },
    },
  }
end

local function build_file_renderer()
  return {
    { "indent" },
    { "icon" },
    {
      "container",
      content = {
        { "name", zindex = 10 },
        { "symlink_target", zindex = 10, highlight = "NeoTreeSymbolicLinkTarget" },
        { "clipboard", zindex = 10 },
        { "bufnr", zindex = 10 },
        { "modified", zindex = 20, align = "right" },
        { "diagnostics", zindex = 20, align = "right" },
        { "git_status", zindex = 10, align = "right" },
        { "last_commit", zindex = 15, align = "right", required_width = 110 },
      },
    },
  }
end

local function show_commit_details(state)
  local node = state and state.tree and state.tree:get_node()
  if not node or type(node.path) ~= "string" or node.path == "" then
    vim.notify("无法获取当前节点", vim.log.levels.WARN)
    return
  end
  local path = node.path
  local root = get_git_root(path)
  if not root then
    vim.notify("不在 git 仓库中", vim.log.levels.WARN)
    return
  end

  local entry = cache[path]
  if not entry then
    fetch(path, root)
    vim.notify("正在获取最近一次 commit, 请稍后重试", vim.log.levels.INFO)
    return
  end
  if not entry.hash or entry.hash == "" then
    vim.notify("该文件/目录暂无 commit 记录", vim.log.levels.WARN)
    return
  end

  vim.cmd("DiffviewOpen " .. entry.hash .. "^! -- " .. vim.fn.fnameescape(path))
end

return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = function(_, opts)
    ensure_highlights()
    vim.api.nvim_create_autocmd("ColorScheme", {
      callback = ensure_highlights,
    })

    -- 顶栏冻结显示当前项目根目录, cwd 变化时自动刷新
    local group = vim.api.nvim_create_augroup("NeoTreeWinbarPath", { clear = true })
    vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinEnter" }, {
      group = group,
      callback = function(args)
        if vim.bo[args.buf].filetype ~= "neo-tree" then
          return
        end
        local win = vim.fn.bufwinid(args.buf)
        vim.schedule(function()
          if not win or win == -1 or not vim.api.nvim_win_is_valid(win) then
            return
          end
          pcall(vim.api.nvim_set_option_value, "winbar",
            " %#NeoTreeRootName#%{fnamemodify(getcwd(),':~')}%* ",
            { scope = "local", win = win })
        end)
      end,
    })
    vim.api.nvim_create_autocmd("DirChanged", {
      group = group,
      callback = function()
        vim.cmd("redrawstatus!")
      end,
    })

    opts.filesystem = opts.filesystem or {}
    opts.filesystem.components = opts.filesystem.components or {}
    opts.filesystem.components.last_commit = last_commit

    opts.filesystem.commands = opts.filesystem.commands or {}
    opts.filesystem.commands.gitlog_show_commit = show_commit_details

    opts.filesystem.window = opts.filesystem.window or {}
    opts.filesystem.window.mappings = opts.filesystem.window.mappings or {}
    opts.filesystem.window.mappings["L"] = "gitlog_show_commit"

    opts.filesystem.renderers = opts.filesystem.renderers or {}
    opts.filesystem.renderers.directory = build_dir_renderer()
    opts.filesystem.renderers.file = build_file_renderer()

    opts.default_component_configs = opts.default_component_configs or {}
    opts.default_component_configs.last_commit = { time_width = 14, author_width = 10, msg_width = 50 }

    vim.api.nvim_create_user_command("NeoTreeGitLogClearCache", function()
      cache = {}
      pending = {}
      queue = {}
      running = 0
      roots = {}
      pcall(function()
        require("neo-tree.sources.manager").refresh("filesystem")
      end)
    end, {})
  end,
  },
}
