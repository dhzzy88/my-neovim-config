-- 高亮不同的单词, 常驻 buffer, 只有按 <Esc> 才清除
-- <leader>hh : 高亮/取消高亮当前光标所在单词 (toggle)
-- <Esc>      : 清除全部单词高亮 (同时保留 nohlsearch 行为)
local M = {}

-- 高亮色板 (不同单词轮流使用不同颜色), 深色文字 + 亮色背景保证可读
local colors = {
  { bg = "#e06c75", fg = "#1c1c1c" },
  { bg = "#98c379", fg = "#1c1c1c" },
  { bg = "#e5c07b", fg = "#1c1c1c" },
  { bg = "#61afef", fg = "#1c1c1c" },
  { bg = "#c678dd", fg = "#1c1c1c" },
  { bg = "#56b6c2", fg = "#1c1c1c" },
  { bg = "#d19a66", fg = "#1c1c1c" },
  { bg = "#ff6ac1", fg = "#1c1c1c" },
}

local GROUP_PREFIX = "HlWord"

-- word -> color index (1-based)
local words = {}

local function ensure_hl()
  for i, c in ipairs(colors) do
    vim.api.nvim_set_hl(0, GROUP_PREFIX .. i, { bg = c.bg, fg = c.fg, bold = true })
  end
end

-- 精确匹配整个单词: \V(very nomagic) + \< \> 词边界
local function pattern_for(word)
  return [[\V\<]] .. vim.fn.escape(word, [[\]]) .. [[\>]]
end

local function clear_win(win)
  vim.api.nvim_win_call(win, function()
    for _, m in ipairs(vim.fn.getmatches()) do
      if type(m.group) == "string" and m.group:sub(1, #GROUP_PREFIX) == GROUP_PREFIX then
        pcall(vim.fn.matchdelete, m.id)
      end
    end
  end)
end

local function apply_win(win)
  vim.api.nvim_win_call(win, function()
    for word, idx in pairs(words) do
      vim.fn.matchadd(GROUP_PREFIX .. idx, pattern_for(word))
    end
  end)
end

local function refresh_win(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  clear_win(win)
  apply_win(win)
end

local function refresh_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    refresh_win(win)
  end
end

-- 分配一个尚未使用的颜色, 全部用完则循环复用
local function next_index()
  local used = {}
  local n = 0
  for _, idx in pairs(words) do
    used[idx] = true
    n = n + 1
  end
  for i = 1, #colors do
    if not used[i] then
      return i
    end
  end
  return (n % #colors) + 1
end

function M.toggle()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    return
  end
  if words[word] then
    words[word] = nil
  else
    words[word] = next_index()
  end
  refresh_all()
end

function M.clear()
  words = {}
  refresh_all()
end

function M.setup()
  ensure_hl()

  local map = vim.keymap.set
  map("n", "<leader>hh", M.toggle, { desc = "highlight word under cursor (toggle)" })
  -- 保留 LazyVim 默认 <Esc> 的 nohlsearch, 同时清除单词高亮
  map("n", "<Esc>", function()
    vim.cmd("nohlsearch")
    M.clear()
  end, { desc = "clear search & word highlights" })

  local aug = vim.api.nvim_create_augroup("HighlightWords", { clear = true })
  -- 新窗口/切换窗口时重新应用, 让高亮"常驻"到当前 buffer 的所有窗口
  vim.api.nvim_create_autocmd({ "WinEnter", "BufWinEnter" }, {
    group = aug,
    callback = function()
      refresh_win(vim.api.nvim_get_current_win())
    end,
  })
  -- 换主题后高亮组会被重置, 重新定义并刷新
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = aug,
    callback = function()
      ensure_hl()
      refresh_all()
    end,
  })
end

return M
