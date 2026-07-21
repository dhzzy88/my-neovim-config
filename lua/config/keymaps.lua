-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
--
local map = vim.keymap.set
map("n", "<leader>gH", "<cmd>DiffviewFileHistory<cr>", { desc = "git history of branch" })
map("n", "<leader>gf", "<cmd>DiffviewFileHistory %<cr>", { desc = "git history of file" })

map("n", "<leader>fs", "<cmd>AutoSession search<cr>", { desc = "find a session" })
map("n", "<leader>fA", function() require("config.agent_session").find() end, { desc = "find AI agent session" })

-- 左侧neo-tree目录下按backspace键可退至上一层目录
-- 当前打开的buffer跟目的文件做diff: vertical diffsplit init.lua



-- 将当前文件完整路径和当前行号复制到系统剪切板
map("n", "<leader>cf", "<cmd>let @+=expand('%:p').':'.line('.')<cr>", {desc = "copy current file path"})


-- switch to next buffer or previous buffer
map("n", "<leader><Left>", "<cmd>bprevious<cr>", {desc = "next buffer"})
map("n", "<leader><Right>", "<cmd>bnext<cr>", {desc = "next buffer"})

-- override default <leader>gb to git blames all lines
map("n", "<leader>gb", "<cmd>Gitsigns blame<cr>", { desc = "git blames all lines" })


-- override quit all command, save session before that
map("n", "<leader>qq", "<cmd>SessionSave<cr>|<cmd>qa<cr>", { desc = "Save session & Quit All" })

map('n', '<leader>ds', '<cmd>lua delete_lines_with_clipboard_content()<CR>', { noremap = true, silent = true, desc = "delete all lines contains clipboard content" })



map("n", "<leader>ft", function()
  -- fn_transform=false 禁用 fzf-lua 默认的 24 字符 padding (会让所有 tag 名长度相同)
  -- --nth=1 / --delimiter=[\t]: 只匹配第一字段(tag 名), 不参与文件路径/ex_cmd 评分
  -- --tiebreak=chunk: 比较被匹配的 chunk(field 1) 长度, 而非整行长度 (length tiebreak 是整行, 会被 ex_cmd 长度干扰)
  require("fzf-lua").tags({
    fn_transform = false,
    fzf_opts = { ["--nth"] = "1", ["--tiebreak"] = "chunk,begin" },
  })
end, { desc = "search all ctags" })
map("n", "<leader>fd", "<cmd>FzfLua tags_grep_cword<cr>", { desc = "grep definitions from ctags of current word" })
map("n", "<leader>fT", function()
  require("fzf-lua").tags({
    query = vim.fn.expand("<cword>"),
    fn_transform = false,
    fzf_opts = { ["--nth"] = "1", ["--tiebreak"] = "chunk,begin" },
  })
end, { desc = "search all ctags (prefilled with cword)" })


map("n", "<leader>gd", "<cmd>Lspsaga peek_definition<cr>", { desc = "lspsaga: go to peek_definition" })
-- <leader>sr  插件grug-far.nvim, 查找并替换
map("n", "<leader>fB", "<cmd>Telescope bookmarks<cr>", { desc = "open bookmarks list" })

local cache = require("gitsigns.cache").cache
local async = require("gitsigns.async")

local api = vim.api

--- 异步获取当前行的 blame commit 信息, 并通过回调处理
---@param cb fun(entry: table) 回调, entry.commit.sha / entry.commit.abbrev_sha 可用
local function with_current_line_commit(cb)
  async.run(function()
    local bufnr = api.nvim_get_current_buf()
    local bcache = cache[bufnr]
    if not bcache then
      return
    end
    bcache:get_blame()
    local blame = bcache.blame
    if not blame then
      return
    end
    local cursor = api.nvim_win_get_cursor(0)[1]
    local entry = blame.entries[cursor]
    if not entry or not entry.commit or not entry.commit.sha or entry.commit.sha:match("^0+$") then
      vim.schedule(function()
        vim.notify("No commit found for current line", vim.log.levels.WARN)
      end)
      return
    end
    vim.schedule(function()
      cb(entry)
    end)
  end)
end

api.nvim_create_user_command("OpenCommitInfoOfCurrLine", function()
  with_current_line_commit(function(entry)
    vim.cmd(string.format("DiffviewOpen %s^!", entry.commit.abbrev_sha))
  end)
end, {})

-- find the commit of current line, and open all diff view of that commit
map("n", "<leader>ga", "<cmd>OpenCommitInfoOfCurrLine<cr>", { desc = "diffview of commit of current line" })
map("n", "<leader>gr", "<cmd>Gitsigns reset_buffer<cr>", { desc = "restore current buffer" })
map("n", "<leader>go", "<cmd>DiffviewOpen<cr>", { desc = "git view open by DiffviewOpen" })

-- 在浮动终端中执行 git commit, 避免 :! 嵌套 nvim 卡死
-- GIT_EDITOR=nvim 显式指定编辑器, 否则会 fallback 到 vi 而 vi 在 snacks 浮动终端内启动会失败
map("n", "<leader>gc", function()
  Snacks.terminal("GIT_EDITOR=nvim git commit -v", {
    win = { position = "float", width = 0.9, height = 0.85 },
  })
end, { desc = "git commit (in floating terminal)" })

-- 覆盖snacks插件默认的gB: 打开当前行 blame commit 对应的 GitHub 页面; 如果是公司内部git, 需要在plugins/git.lua中配置
map("n", "<leader>gB", function()
  with_current_line_commit(function(entry)
    Snacks.gitbrowse({
      what = "commit",
      commit = entry.commit.sha,
      -- 自定义 open: 在 :messages 中打印链接(SSH无GUI时方便复制), 同时尝试浏览器打开
      open = function(url)
        vim.api.nvim_echo({ { "Git Browse: ", "Title" }, { url, "Underlined" } }, true, {})
        vim.fn.setreg("+", url)
        vim.ui.open(url)
      end,
    })
  end)
end, { desc = "git browse: open blame commit" })

