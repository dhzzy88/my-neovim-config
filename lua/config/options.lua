-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- LazyVim 在检测到 SSH_CONNECTION 时会清空 clipboard, 这里强制开启,
-- 配合 init.lua 中 vim.g.clipboard 的 OSC52 provider 实现远程剪贴板同步
vim.opt.clipboard = "unnamedplus"
vim.o.autoread = true
