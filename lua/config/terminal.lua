-- ============================================================
-- terminal.lua
--
-- 统一管理两类内嵌终端:
--   1) Snacks.terminal (浮动/分割窗口的 nvim 内嵌 terminal)
--   2) tmux-pane      (主 window 右侧 pane, 隐藏的存放在 _parked window)
--
-- 设计模型 (见 design.md):
--   - 全局模式 M.mode ∈ {"snacks","tmux"}, 决定新建/显示走哪类终端
--   - 5 个业务操作: toggle_mode / new_terminal / toggle_terminal /
--                   list_terminals / send_reference
-- ============================================================

local M = {}

-- 隐藏的 tmux pane 寄存在一个独立的 detached session, 每个 pane 占一个 window
-- 这样 pane 始终独占整个 window 宽度, capture-pane 抓到的内容才是完整宽度
local PARKED_SESSION = "_nvim_parked"
local PARKED_W = 250
local PARKED_H = 80

-- 终端窗口占主窗口的宽度比例 (0~1). 调整这一处即可同步两类终端
local WIDTH_RATIO = 0.30
local WIDTH_PERCENT = string.format("%d%%", math.floor(WIDTH_RATIO * 100))

M.mode = (vim.env.TMUX ~= nil and vim.env.TMUX ~= "") and "tmux" or "snacks"
M._mru = { snacks = {}, tmux = {} } -- 末尾元素为最近活跃

-- ============================================================
-- 通用 tmux 工具
-- ============================================================

local function in_tmux()
  return vim.env.TMUX ~= nil and vim.env.TMUX ~= ""
end

local function require_tmux()
  if not in_tmux() then
    vim.notify("当前不在 tmux 环境中", vim.log.levels.WARN)
    return false
  end
  return true
end

local function tmux_run(args)
  return vim.fn.system(vim.list_extend({ "tmux" }, args))
end

local function tmux_get(args)
  return (tmux_run(args) or ""):gsub("%s+$", "")
end

-- nvim 自身所在的 pane id (由 tmux 注入到环境变量 TMUX_PANE)
-- 一旦 nvim 启动就锚定, 不会因 client 切换 window 而漂移
local function nvim_pane_id()
  return vim.env.TMUX_PANE or ""
end

local function current_session()
  local nv = nvim_pane_id()
  if nv ~= "" then
    return tmux_get({ "display-message", "-p", "-t", nv, "#{session_name}" })
  end
  return tmux_get({ "display-message", "-p", "#{session_name}" })
end

-- 主 window (nvim 所在 window) 右侧 slot pane id, 不存在返回 nil
-- 实现: 列出 nvim 所在 window 的所有 pane, 排除 nvim 自身, 取 pane_left 最大的那个
local function get_right_pane_id()
  local nv = nvim_pane_id()
  if nv == "" then return nil end
  local out = tmux_get({
    "list-panes", "-t", nv,
    "-F", "#{pane_id}\t#{pane_left}",
  })
  local best_id, best_left = nil, -1
  for line in out:gmatch("[^\n]+") do
    local id, left = line:match("^(%S+)\t(%d+)$")
    if id and id ~= nv then
      local l = tonumber(left) or 0
      if l > best_left then
        best_id, best_left = id, l
      end
    end
  end
  return best_id
end

-- ============================================================
-- parking session 工具
-- ============================================================

local function parked_session_exists()
  local out = tmux_get({ "list-sessions", "-F", "#{session_name}" })
  for line in out:gmatch("[^\n]+") do
    if line == PARKED_SESSION then return true end
  end
  return false
end

local function ensure_parked_session()
  if not parked_session_exists() then
    -- detached, 显式指定尺寸, 避免无 client attach 时被压缩
    tmux_run({ "new-session", "-d", "-s", PARKED_SESSION, "-x", tostring(PARKED_W), "-y", tostring(PARKED_H) })
  end
end

local function list_parked_panes()
  if not parked_session_exists() then return {} end
  -- -s 列出 session 下全部 window 的全部 pane
  local out = tmux_get({
    "list-panes", "-s", "-t", PARKED_SESSION,
    "-F", "#{pane_id}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}",
  })
  local items = {}
  for line in out:gmatch("[^\n]+") do
    local id, cmd, title, path = line:match("^(%S+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if id then
      table.insert(items, { id = id, cmd = cmd or "", title = title or "", path = path or "" })
    end
  end
  return items
end

-- ============================================================
-- MRU helpers
-- ============================================================

local function mru_touch(kind, key)
  local q = M._mru[kind]
  for i, v in ipairs(q) do
    if v == key then table.remove(q, i); break end
  end
  table.insert(q, key)
end

local function mru_remove(kind, key)
  local q = M._mru[kind]
  for i, v in ipairs(q) do
    if v == key then table.remove(q, i); return end
  end
end

local function mru_last(kind)
  local q = M._mru[kind]
  return q[#q]
end

-- ============================================================
-- 后端 A: snacks-terminal
-- ============================================================

local function snacks_list()
  return Snacks.terminal.list()
end

local function snacks_visible_terms()
  local out = {}
  for _, t in ipairs(snacks_list()) do
    if t:win_valid() then table.insert(out, t) end
  end
  return out
end

local function snacks_hide_all()
  for _, t in ipairs(snacks_visible_terms()) do
    t:hide()
  end
end

-- 把 term 显示并聚焦; 如果当前已有其他 snacks term 显示, 复用其窗口
local function snacks_show(term)
  for _, t in ipairs(snacks_list()) do
    if t == term and t:win_valid() then
      t:focus()
      mru_touch("snacks", t.buf)
      return
    end
  end
  -- 复用已有 visible window 以避免叠开多个
  for _, t in ipairs(snacks_list()) do
    if t:win_valid() and t ~= term then
      local existing_win = t.win
      t.win = nil
      if existing_win and vim.api.nvim_win_is_valid(existing_win) then
        vim.api.nvim_win_set_buf(existing_win, term.buf)
        term.win = existing_win
        vim.wo[existing_win].number = false
        vim.wo[existing_win].relativenumber = false
        vim.api.nvim_set_current_win(existing_win)
        mru_touch("snacks", term.buf)
        return
      end
    end
  end
  term:show():focus()
  mru_touch("snacks", term.buf)
end

-- 创建新 snacks terminal; count 用于区分多个独立实例
local function snacks_new(count)
  count = count or 1
  -- 通过 env 注入 count, Snacks.terminal 内置按 cmd+cwd+env 索引, 同 count 复用同实例
  local term = Snacks.terminal.get(nil, {
    create = true,
    win = { position = "right", width = WIDTH_RATIO },
    env = { TERMINAL_SLOT = tostring(count) },
  })
  if term then mru_touch("snacks", term.buf) end
  return term
end

-- ============================================================
-- 后端 B: tmux-pane
-- ============================================================

local function tmux_create_right_pane()
  local nv = nvim_pane_id()
  if nv == "" then return nil end
  -- 在 nvim 所在 pane 右侧 split, 不切换焦点 (-d)
  -- -P 打印新 pane 的 id
  local new_id = tmux_get({ "split-window", "-h", "-d", "-l", WIDTH_PERCENT, "-t", nv, "-P", "-F", "#{pane_id}" })
  if new_id == "" then return nil end
  return new_id
end

local function tmux_hide_right()
  local slot = get_right_pane_id()
  if not slot then return end
  ensure_parked_session()
  -- 把 slot pane break 出去, 作为 parked session 末尾的新 window, 独占整 window 宽度
  tmux_run({ "break-pane", "-d", "-a", "-s", slot, "-t", PARKED_SESSION .. ":" })
end

local function tmux_show_pane(pane_id)
  -- 先把右侧已有 slot 收回 parking, 保证一次只显示一个
  if get_right_pane_id() then
    tmux_hide_right()
  end
  -- 把目标 pane 从 parking session join 到 nvim 右侧
  local nv = nvim_pane_id()
  tmux_run({ "join-pane", "-d", "-h", "-l", WIDTH_PERCENT, "-s", pane_id, "-t", nv })
  mru_touch("tmux", pane_id)
end

-- 新建 pane (直接在右侧创建, 不走 parking)
local function tmux_new_pane()
  ensure_parked_session()
  -- 如果右侧已经有 slot, 先把它收回 parking
  if get_right_pane_id() then
    tmux_hide_right()
  end
  local new_id = tmux_create_right_pane()
  mru_touch("tmux", new_id)
  return new_id
end

-- 列出全部 tmux pane: 右侧 slot (若有) + parking 内的
local function tmux_list_all_panes()
  if not in_tmux() then return {} end
  local panes = {}
  local right = get_right_pane_id()
  if right then
    local out = tmux_get({
      "display-message", "-p", "-t", right,
      "-F", "#{pane_id}\t#{pane_current_command}\t#{pane_title}\t#{pane_current_path}",
    })
    local id, cmd, title, path = out:match("^(%S+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if id then
      table.insert(panes, { id = id, cmd = cmd or "", title = title or "", path = path or "", visible = true })
    end
  end
  for _, p in ipairs(list_parked_panes()) do
    p.visible = false
    table.insert(panes, p)
  end
  return panes
end

local function tmux_kill_pane(pane_id)
  tmux_run({ "kill-pane", "-t", pane_id })
  mru_remove("tmux", pane_id)
end

-- ============================================================
-- 统一 API
-- ============================================================

-- 当前主窗口右侧是否已经显示了一个内嵌终端 (任意类型)
function M.is_terminal_visible()
  if #snacks_visible_terms() > 0 then return "snacks" end
  if in_tmux() and get_right_pane_id() then return "tmux" end
  return nil
end

-- 把文本发送给当前可见终端, 没有可见则返回 false
local function send_to_visible(text)
  local kind = M.is_terminal_visible()
  if kind == "tmux" then
    local right = get_right_pane_id()
    if not right then return false end
    vim.fn.system({ "tmux", "send-keys", "-t", right, text })
    return true
  elseif kind == "snacks" then
    local terms = snacks_visible_terms()
    local last = terms[#terms]
    if not last then return false end
    local ok, chan = pcall(vim.api.nvim_buf_get_var, last.buf, "terminal_job_id")
    if not ok or not chan then return false end
    vim.api.nvim_chan_send(chan, text)
    return true
  end
  return false
end

-- ============================================================
-- 业务操作
-- ============================================================

-- 操作 1: 切换全局模式
function M.toggle_mode()
  if M.mode == "snacks" then
    if not require_tmux() then return end
    M.mode = "tmux"
  else
    M.mode = "snacks"
  end
  vim.notify("terminal mode -> " .. M.mode)
end

-- 操作 2: 新建终端 (按当前模式)
-- 若当前已有可见终端, 先隐藏再显示新建的
function M.new_terminal(count)
  count = count or 1
  local visible = M.is_terminal_visible()

  if M.mode == "tmux" then
    if not require_tmux() then return end
    -- 隐藏所有 snacks 可见终端
    snacks_hide_all()
    -- tmux_new_pane 内部会处理右侧旧 pane
    tmux_new_pane()
  else
    -- snacks 模式
    if visible == "tmux" then
      tmux_hide_right()
    end
    -- 新建 snacks 可能复用同 count 实例; 隐藏其他可见后再 show 它
    local term = snacks_new(count)
    if not term then
      vim.notify("创建 snacks terminal 失败", vim.log.levels.ERROR)
      return
    end
    -- 隐藏其他 visible terms 后显示这个
    for _, t in ipairs(snacks_visible_terms()) do
      if t ~= term then t:hide() end
    end
    snacks_show(term)
  end
end

-- 操作 3: 显示/隐藏内嵌终端
function M.toggle_terminal()
  local visible = M.is_terminal_visible()
  if visible == "snacks" then
    snacks_hide_all()
    return
  elseif visible == "tmux" then
    tmux_hide_right()
    return
  end

  -- 没有可见终端, 按当前模式恢复最近活跃的; 若没有则新建
  if M.mode == "tmux" then
    if not require_tmux() then return end
    local last_id = mru_last("tmux")
    if last_id then
      -- 校验 pane 是否仍然存在
      local found = false
      for _, p in ipairs(list_parked_panes()) do
        if p.id == last_id then found = true; break end
      end
      if found then
        tmux_show_pane(last_id)
        return
      end
    end
    tmux_new_pane()
  else
    local last_buf = mru_last("snacks")
    local target
    if last_buf then
      for _, t in ipairs(snacks_list()) do
        if t.buf == last_buf then target = t; break end
      end
    end
    if not target then
      target = snacks_list()[1]
    end
    if target then
      snacks_show(target)
    else
      M.new_terminal(1)
    end
  end
end

-- 操作 4: 列出所有终端 (合并 picker)
function M.list_terminals()
  local function build_term_entry(term)
    local info = vim.b[term.buf].snacks_terminal
    if not info then return nil end
    local cmd_str = type(info.cmd) == "table" and table.concat(info.cmd, " ") or (info.cmd or "shell")
    local cwd_str = info.cwd and vim.fn.fnamemodify(info.cwd, ":~") or vim.fn.getcwd()
    local visible = term:win_valid() and "[显示]" or "[隐藏]"
    return {
      kind = "term",
      text = string.format("[term #%d] %s  %s  %s", info.id, cmd_str, cwd_str, visible),
      term = term,
      buf = term.buf,
      info = info,
    }
  end

  local function build_pane_entry(pane)
    local path = pane.path ~= "" and vim.fn.fnamemodify(pane.path, ":~") or ""
    local visible = pane.visible and "[显示]" or "[隐藏]"
    return {
      kind = "pane",
      text = string.format("[pane %s] %s  %s  %s", pane.id, pane.cmd, path, visible),
      pane = pane,
    }
  end

  local function entry_path(e)
    if e.kind == "term" then
      return e.info and e.info.cwd or ""
    else
      return e.pane and e.pane.path or ""
    end
  end

  local function build_entries()
    local entries = {}
    for _, term in ipairs(snacks_list()) do
      local e = build_term_entry(term)
      if e then table.insert(entries, e) end
    end
    for _, p in ipairs(tmux_list_all_panes()) do
      table.insert(entries, build_pane_entry(p))
    end

    -- 当前项目路径匹配的优先排在前面 (稳定排序)
    local cwd = vim.fn.getcwd()
    local matched, others = {}, {}
    for _, e in ipairs(entries) do
      if entry_path(e) == cwd then
        table.insert(matched, e)
      else
        table.insert(others, e)
      end
    end
    return vim.list_extend(matched, others)
  end

  if #build_entries() == 0 then
    vim.notify("没有可选的 terminal 或 tmux pane", vim.log.levels.WARN)
    return
  end

  Snacks.picker.pick({
    source = "terminals_unified",
    title = "Terminals (mode=" .. M.mode .. ") | <ctrl-x> 关闭",
    finder = build_entries,
    format = function(item) return { { item.text, "Normal" } } end,
    preview = function(ctx)
      ctx.preview:reset()
      local item = ctx.item
      if not item then return end
      if item.kind == "pane" then
        ctx.preview:set_title("pane " .. item.pane.id)
        Snacks.picker.preview.cmd({ "tmux", "capture-pane", "-t", item.pane.id, "-p", "-e" }, ctx)
      elseif item.kind == "term" then
        ctx.preview:set_title("term #" .. item.info.id)
        if vim.api.nvim_buf_is_valid(item.buf) then
          ctx.preview:set_buf(item.buf)
        end
      end
    end,
    confirm = function(picker, item)
      picker:close()
      if not item then return end
      if item.kind == "pane" then
        snacks_hide_all()
        tmux_show_pane(item.pane.id)
      else
        if in_tmux() and get_right_pane_id() then
          tmux_hide_right()
        end
        snacks_show(item.term)
      end
    end,
    actions = {
      kill_item = function(picker, item)
        if not item then return end
        if item.kind == "pane" then
          tmux_kill_pane(item.pane.id)
        else
          picker.preview:reset()
          item.term:close()
          mru_remove("snacks", item.buf)
        end
        vim.schedule(function() picker:find({ refresh = true }) end)
      end,
    },
    win = {
      input = { keys = { ["<C-x>"] = { "kill_item", mode = { "n", "i" } } } },
      list = { keys = { ["<C-x>"] = "kill_item" } },
    },
  })
end

-- 操作 5: 新建终端并在其中执行命令 (供外部调用, 如 agent session resume)
function M.run_in_new_terminal(cmd, count)
  if not cmd or cmd == "" then return end
  M.new_terminal(count or 1)
  local kind = M.is_terminal_visible()
  if kind == "tmux" then
    local right = get_right_pane_id()
    if not right then return end
    -- 给 shell 一点初始化时间, 否则首字符可能丢失
    vim.defer_fn(function()
      vim.fn.system({ "tmux", "send-keys", "-t", right, cmd, "Enter" })
    end, 80)
  elseif kind == "snacks" then
    local terms = snacks_visible_terms()
    local last = terms[#terms]
    if not last then return end
    vim.defer_fn(function()
      local ok, chan = pcall(vim.api.nvim_buf_get_var, last.buf, "terminal_job_id")
      if ok and chan then
        vim.api.nvim_chan_send(chan, cmd .. "\n")
      end
    end, 100)
  end
end

-- 操作 6: 在编辑窗口内向终端发送 @引用
function M.send_reference()
  local mode = vim.fn.mode()
  local rel_path = vim.fn.expand("%:.")
  if rel_path == "" then
    vim.notify("当前 buffer 没有文件路径", vim.log.levels.WARN)
    return
  end

  local payload
  if mode == "v" or mode == "V" or mode == "\22" then
    local s = vim.fn.line("v")
    local e = vim.fn.line(".")
    if s > e then s, e = e, s end
    payload = rel_path .. ":" .. s .. "-" .. e
    -- 退出 visual 模式
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
  else
    payload = rel_path
  end

  vim.fn.setreg("+", payload)
  local sent = send_to_visible("@" .. payload .. " ")
  if sent then
    vim.notify("已复制并引用: " .. payload)
  else
    vim.notify("已复制: " .. payload .. " (无可见终端)", vim.log.levels.WARN)
  end
end

-- ============================================================
-- keymaps
-- ============================================================
local map = vim.keymap.set
map("n", "<leader>tm", M.toggle_mode,                                { desc = "terminal: 切换模式 (snacks/tmux)" })
map("n", "<leader>tn", function() M.new_terminal(vim.v.count1) end,  { desc = "terminal: 新建" })
map("n", "<leader>tt", M.toggle_terminal,                            { desc = "terminal: 显示/隐藏" })
map("n", "<leader>tl", M.list_terminals,                             { desc = "terminal: 列出全部" })
map({ "n", "v" }, "<leader>r", M.send_reference,                     { desc = "terminal: 发送 @引用" })

return M
