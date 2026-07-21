-- bootstrap lazy.nvim, LazyVim and your plugins
vim.cmd.source(vim.fn.stdpath("config") .. "/vimrc")

-- 禁止通过osc52复制太多内容, 防止删除很多内容时乱码刷屏
local function copy_to_clipboard(text)
  if #text > 20000 then
    print("Skip copy")
    return
  end
  require("vim.ui.clipboard.osc52").copy("+")(text)
end
local function paste()
  return {
    vim.split(vim.fn.getreg(""), "\n"),
    vim.fn.getregtype(""),
  }
end
local platform = vim.loop.os_uname().sysname
if platform == "Linux" or platform == "Darwin" then
  vim.g.clipboard = {
    name = "OSC 52",
    copy = {
      ["+"] = copy_to_clipboard,
      ["*"] = copy_to_clipboard,
    },
    paste = {
      ["+"] = paste,
      ["*"] = paste,
    },
  }
elseif platform == "Win32" then
end

vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile", "BufReadPost" }, {
  group = vim.api.nvim_create_augroup("SyslogFileType", { clear = true }),
  desc = "Set filetype to test if filename contains 'syslog'",
  pattern = "*syslog*",
  callback = function()
    vim.cmd("set filetype=sonic-syslog")
  end,
})

-- 定义一个函数来删除包含剪贴板内容的所有行
function _G.delete_lines_with_clipboard_content()
  -- 获取系统剪贴板的内容
  local clipboard_content = vim.fn.getreg("+")
  if clipboard_content == "" then
    vim.notify("Clipboard is empty!", vim.log.levels.ERROR)
    return
  end
  local escaped_content = vim.pesc(clipboard_content)
  local command = ":g/" .. escaped_content .. "/d"
  vim.cmd(command)
  vim.notify(string.format("Deleted lines containing: %s", clipboard_content), vim.log.levels.INFO)
end

require("config.lazy")
require("config.git")
require("config.test")
require("config.lsp")
require("config.session")
require("config.bookmarks")
require("config.others")
require("config.terminal")

require("lspconfig").gopls.setup({})
require("lspconfig").pyright.setup({})
require("lspconfig").clangd.setup({})

require("lualine").setup({})

vim.api.nvim_create_autocmd({ "VimEnter" }, {
  pattern = "*",
  callback = function()
    -- 检测是否处于 vimdiff 模式
    if vim.o.diff then
      vim.cmd.colorscheme("default") -- evening / elflord / koehler
    end
  end,
})

vim.g.autoformat = false -- 关闭nvim-lspconfig默认使能的保持时自动格式化文件
vim.o.showtabline = 2
vim.wo.relativenumber = false
vim.opt.foldmethod = "expr"
vim.opt.foldexpr = "nvim_treesitter #foldexpr ()"
vim.opt.foldlevel = 99
vim.opt.shiftwidth = 4 -- tab设置为4个spaces
vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions"
vim.g.bigfile_size = 1024 * 1024 * 10 -- 设置大文件为50MB, 超过限制的大文件会自动关闭语法高亮等
-- vim.o.signcolumn = "no" -- 行号不会出现灯泡, 从而把代码往右挤



-- 1. 定义你想看的符号
vim.opt.listchars = {
  space = "·", -- 空格画中间点
  tab = "› ", -- 制表符画 › + 延伸线
  trail = "·", -- 行尾空格
  nbsp = "·",
}
-- 默认先不显示
vim.opt.list = false

-- 2. 自动命令：进入/离开 Visual 模式时切换 list
local group = vim.api.nvim_create_augroup("ShowWhiteOnVisual", { clear = true })
vim.api.nvim_create_autocmd("ModeChanged", {
  pattern = "*:[vV\x16]*", -- 进入 Visual/块选
  group = group,
  callback = function()
    vim.opt.list = true
  end,
})
vim.api.nvim_create_autocmd("ModeChanged", {
  pattern = "[vV\x16]*:*", -- 离开 Visual/块选
  group = group,
  callback = function()
    vim.opt.list = false
  end,
})

-- vim.g.snacks_animate = false -- 默认使能snack动画, 但是搜索时不及时显示匹配序号
vim.cmd("colorscheme vscode")
vim.cmd("hi link bookmarks_virt_text_hl BufferLineGroupLabel") -- 设置书签的显示格式

vim.opt.cursorline = true -- 光标所在行高亮
vim.opt.cursorcolumn = true -- 光标所在列高亮
vim.api.nvim_set_hl(0, "CursorLine", { bg = "#2f2f2f" }) -- vscode主题的背景色是#202020
vim.api.nvim_set_hl(0, "CursorColumn", { bg = "#222222" }) -- vscode主题的背景色是#202020
