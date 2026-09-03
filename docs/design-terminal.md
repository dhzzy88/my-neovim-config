# 开发目的 
设计一套neovim快捷键映射到自定义函数里，完成一系列关于内嵌终端的操作。这里的内嵌终端有两类: 
•  snacks插件的终端，Snacks.terminal 
• (如果在tmux环境内)，在当前窗口右侧打开一个pane作为内嵌终端 要求两类终端能够支持相同的操作，实现统一管理。

# 工具函数 
1. 判断当前是否处在tmux环境里。 
2. 设置一个全局变量，表示当前的模式(snacks-terminal或者tmux-pane) 
    3. 判断当前窗口是否已经打开内嵌终端。不管是哪种终端类型，当前窗口只要在右侧打开了其中一种，就认为是打开终端状态。 
    4.支持捕获终端的当前内容，保留颜色
    5.支持向指定终端内发送内容

# 业务操作 
    每一个业务操作应该对应一个函数，考虑抽象和复用性。
     •  操作1: 切换当前的模式。执行操作1后全局模式从一个切换到另一个。反复执行，则反复切换。注意，只有在tmux环境下才支持切换到tmux-pane模式，后面所有的操作都需要考虑这一点。
      •  操作2: 新建内嵌终端。本操作可以接收一个数字作为终端的id参数，两类终端分开索引，如果用户不传入数字，则默认为数字1。根据当前的全局模式，新建对应的终端。例如当前模式是snacks-terminal时，执行操作2会新建一个snacks-terminal；反之，如果是tmux-pane模式，会新建一个tmux-pane。注意: 执行操作2时，要判断当前窗口是否已经打开了终端，如果没有，则把新创建的终端显示在窗口右侧；如果已经打开了，则将已经打开的终端隐藏，并显示刚才新建的终端。
       •  操作3: 显示/隐藏内嵌终端。需要先判断当前窗口是否已经打开了终端，如果打开了，执行操作3后将其隐藏；如果没有打开，则判断当前环境下是否存在已经创建好但是隐藏的终端，如果有隐藏的，则执行操作3后把最近活跃的那个终端重新显示出来，如果没有隐藏的，则调用操作2新建一个终端并显示。 
       •  操作4: 显示所有已经创建的终端。执行操作4后会打开一个picker选择界面，可以把当前已经创建的所有终端(包括snacks.terminal和tmux-pane)都一一列出来，picker预览界面里需要渲染出该终端的最新状态和内容。用户调用picker逻辑可以选择某个终端后打开，这里的“打开逻辑”是指: 如果当前已经有终端显示，并且用户选择要打开的终端是同一个则忽略；如果不是同一个，则将已经显示的终端隐藏，并替换为用户选择的那个终端。如果当前没有终端显示，则直接打开即可。
       •  操作5: 在编辑窗口内向终端发送内容。光标在编辑窗口内执行操作5后，判断当前是nvim的什么模式。如果是normal模式，则自动获取当前buffer窗口所在的文件相对项目根目录的路径，如a/b.py；如果是visual模式，则还要获取当前选择的行数，如a/b.py:12-33。在上述前提下，再判断右侧是否有已显示的终端，如果有则将刚才获取的字符串str，拼接成“@<str> ”发送给右侧已显示的终端。


# 实现沉淀 (lua/config/terminal.lua)

## 模块结构
```
1. 通用 tmux 工具      (in_tmux / tmux_run / tmux_get / nvim_pane_id / current_session / nvim_window_id / get_right_pane_id)
2. parking window 工具 (parked_window_exists / ensure_parked_window / list_parked_panes)
3. MRU helpers         (mru_touch / mru_remove / mru_last)
4. 后端 A: snacks      (snacks_list / snacks_visible_terms / snacks_hide_all / snacks_show / snacks_new)
5. 后端 B: tmux-pane   (tmux_create_right_pane / tmux_show_pane / tmux_hide_right / tmux_new_pane / tmux_list_all_panes / tmux_kill_pane)
6. 统一 API            (M.is_terminal_visible / send_to_visible)
7. 业务操作            (M.toggle_mode / M.new_terminal / M.toggle_terminal / M.list_terminals / M.send_reference)
8. keymaps
```

## 关键设计

### 默认模式
启动时按环境决定:
- 在 tmux 内: `M.mode = "tmux"`
- 不在 tmux: `M.mode = "snacks"`
`toggle_mode` 切到 tmux 模式时会校验环境, 不在 tmux 则拒绝并提示.

### tmux pane 隐藏机制 (parking window)
tmux 没有原生"隐藏 pane"指令. 采用一个隐藏的 `_parked` window 作为后台存放区, 通过 `join-pane` / `swap-pane` 在主 window 右侧 slot 与 parking 之间转移 pane, 进程状态完整保留.

### 用 `$TMUX_PANE` 锚定 nvim 自身 pane
所有 tmux 命令都显式 `-t <nvim_pane_id>` 指定 target, 不依赖"客户端 current window". 这避免了多 client 看不同 window 时, `split-window` 不带 `-t` 在错误 window 创建 pane 的问题.

### 右侧 slot 探测
`tmux display-message -t <pane>.{right}` 只在 active pane 下生效, 不能从指定 pane 出发查邻居. 改用:
```
tmux list-panes -t <nvim_pane> -F "#{pane_id}\t#{pane_left}"
```
取除 nvim 自身外 `pane_left` 最大者作为右侧 slot.

### 显示 parked pane 的两种路径
- **已有 slot**: `swap-pane -d -s <parked> -t <slot>` (跨 window swap, 旧 slot 进 parking)
- **无 slot**: `join-pane -d -h -l 25% -s <parked> -t <nvim_pane>` (直接接到 nvim 右侧, 不浪费空 pane)

### MRU
`M._mru = { snacks = {}, tmux = {} }`, 末尾为最近活跃. 操作3 恢复隐藏终端时取末尾.
- snacks 用 `term.buf` 作 key
- tmux 用 `pane_id` 作 key

### picker 预览
- snacks 项: `ctx.preview:set_buf(term.buf)` 实时
- tmux 项: `Snacks.picker.preview.cmd({"tmux","capture-pane","-t",id,"-p","-e","-J"}, ctx)` 抓取保留颜色

### `<leader>r` 引用
- normal: `相对路径`
- visual: `相对路径:start-end`, 拼成 `@<payload> ` 发送给当前可见终端 (snacks via `nvim_chan_send`, tmux via `tmux send-keys`), 同时复制到 `+` 寄存器.

## 快捷键
| 操作 | 函数                  | keymap          |
|------|-----------------------|-----------------|
| 1    | `M.toggle_mode`       | `<leader>tm`    |
| 2    | `M.new_terminal`      | `<leader>tn`    |
| 3    | `M.toggle_terminal`   | `<leader>tt`    |
| 4    | `M.list_terminals`    | `<leader>tl`    |
| 5    | `M.send_reference`    | `<leader>r` (n/v) |

## 实现过程踩到的坑

1. **tmux 命令未指定 target**: 多客户端环境下, 不带 `-t` 的 `split-window` 可能在错误 window 创建 pane. 解决方案见"用 `$TMUX_PANE` 锚定".
2. **`{right}` 语义陷阱**: 它是相对 active pane 的方向符, 不能从指定 pane 出发查邻居. 改用 `list-panes` + `pane_left` 排序.
3. **swap-pane 残留空 slot**: 显示 parked pane 时若先创建空 slot 再 swap, 空 slot 会被换到 parking 浪费 pane. 改为根据有无 slot 走不同路径 (swap vs join).
4. **noice cmdline 浮窗**: 通过 `tmux send-keys` 一次性发整个 `:lua ...` 命令时字符可能被丢. 测试脚本中分步发送 `:` → 命令体 → `<Enter>`, 字符之间留 100~150ms.
5. **`tmux send-keys 'foo' Enter` 中的 Escape**: 测试脚本里若先发 `<Esc>` 再发 ` r` 会导致 visual 模式被取消. 应针对场景区分需不需要预先 Escape.


