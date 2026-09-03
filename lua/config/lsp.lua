local map = vim.keymap.set
map("n", "<leader>go", "<cmd>Lspsaga outline<cr>", { desc = "lspsage: open outline('o' to jump)" })
map({ "n", "v" }, "<leader>ca", "<cmd>Lspsaga code_action<cr>", { desc = "code action" })
