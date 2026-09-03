# codetour.nvim 实施计划

**Goal:** 在 Neovim 中复刻 VSCode 插件 CodeTour 的核心能力——通过 `.tour` JSON 文件录制和回放代码导览，在源文件上跳转、行内高亮、浮窗展示 markdown 描述、支持步骤间链接跳转和 shell 命令调用。**额外增强**：所有 tour 文件集中存放在一个全局目录（默认 `~/.local/share/nvim/codetour/tours/`），每个 tour 文件内通过 `projectRoot` 字段绑定到具体项目。这样 tours 目录可整目录迁移到新设备，仅修改 `projectRoot` 即可继续使用。

**Architecture:** 独立 Lua 插件项目，目录放在 `~/projects/codetour.nvim/`（与 nvim 配置完全解耦，便于将来发布到 GitHub），通过 LazyVim 的 `dir = ...` 本地路径加载。**不要**放进 `~/.local/share/nvim/lazy/`：该目录由 lazy.nvim 全权管理，未声明的目录会被自动清理。

模块职责分离：`loader` 读写 `.tour` 文件（从全局 tours 目录扫描），`state` 持有当前 tour/step，`runner` 驱动导航——跳转时用 `tour.projectRoot + step.file` 拼绝对路径，与当前 cwd 无关。`marks`（行内 extmark）和 `ui`（浮动窗口）由 `state` 事件驱动刷新；`markdown` 解析扩展语法（`[#N]` 步骤引用、`>> cmd` shell、`[](command:...)`）；`picker` 走 `snacks.picker` 选 tour/step（按 projectRoot 分组显示）；`recorder` 创建/录制时自动写入 `projectRoot = vim.fn.getcwd()`，并把 step.file 计算成相对 projectRoot 的路径。

**Tech Stack:**
- Lua（Neovim 0.11+ 原生 API：`vim.system` / `vim.json` / `vim.api.nvim_*` / `vim.uv` / `vim.fs`）
- snacks.nvim（picker、notify）
- plenary.nvim（busted 风格测试 + `PlenaryBustedDirectory`）
- LazyVim（用户已有，通过 `dir = ...` 指向本地路径加载）
- treesitter `markdown` 解析器（已被 LazyVim 装载，浮窗 buffer 直接享受高亮）

---

## 0. 阅读这份计划之前

### 0.1 名词速查

- **tour**：一次完整的导览，对应一个 `.tour` JSON 文件。
- **step**：一次导览中的一步，可能定位到「文件某行」「目录」「纯内容」三种之一。
- **tours 目录**：所有 `.tour` 文件的集中存放目录。**与 VSCode CodeTour 不同**，本插件不再扫描各项目的 `.tours/`，而是扫描一个全局目录。默认 `vim.fn.stdpath("data") .. "/codetour/tours"`（即 `~/.local/share/nvim/codetour/tours/`），通过 `setup({ tours_dir = ... })` 可覆盖（推荐配成 `~/Dropbox/codetour-tours` 或 git 管理的目录以便跨设备同步）。
- **projectRoot**：tour 文件内的字段，存项目根目录的绝对路径。支持 `~` 前缀（运行时展开），允许同一台设备上不同项目共存于同一 tours 目录。
- **当前 step 位置标记**：用 `nvim_buf_set_extmark` 在目标行加 sign + 行尾 virt_text，类似 VSCode 左侧三角箭头。
- **浮动窗口**：用 `nvim_open_win({ relative = "editor", border = "rounded" })`，buffer `filetype = "markdown"` 享用 treesitter 高亮。

### 0.2 重要约定

- **行号**：CodeTour 文件中 `line` 是 **1-based**，与 Neovim `nvim_win_set_cursor` 的 row 一致；与 `nvim_buf_set_extmark` 的 row 是 **0-based**，转换时务必注意。
- **路径**：`.tour` 中 `file` 字段是 **相对于 `projectRoot`** 的路径（与 VSCode CodeTour 语义保持一致——VSCode 是相对工作区，我们这里把"工作区"换成 tour 内显式声明的 `projectRoot`），使用 `/` 作分隔符。
- **`projectRoot` 字段是必填**：本插件不做 fallback，缺失即报错。`recorder.new_tour` 会自动写入 `vim.fn.fnamemodify(vim.fn.getcwd(), ":~")`（带 `~` 形式，便于跨用户）。
- **JSON 序列化顺序**：tour 级 `$schema, title, description, projectRoot, ref, isPrimary, nextTour, steps`；step 级 `file/directory/contents, line, pattern, selection, title, description, commands`。`projectRoot` 是本插件扩展字段，VSCode 会忽略它（schema 允许 additionalProperties），保证 .tour 文件双向兼容（在 VSCode 中只是用不上 projectRoot 而已）。
- **缩进**：`.tour` 文件统一两空格缩进，末尾换行。`vim.json.encode` 没有缩进选项，自己实现一个最小 pretty printer（见 Task 1.5）。

### 0.3 全局测试运行命令

每写完一个 task 都用这条命令跑一次全部测试：

```bash
cd ~/projects/codetour.nvim && \
  nvim --headless --noplugin -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"
```

期望输出末尾包含 `Success: <N>` 且 `Errors: 0` `Failed : 0`。

### 0.4 跨设备迁移流程（设计目标演示）

假设设备 A 的 tours 目录在 `~/Dropbox/codetour-tours/`，里面已积累若干 `.tour` 文件（每个内含 `"projectRoot": "~/work/proj-A"`）。迁移到设备 B：

1. Dropbox 自动同步整目录到设备 B。
2. 在设备 B 上 `setup({ tours_dir = "~/Dropbox/codetour-tours" })`。
3. 设备 B 上对应项目可能在 `~/code/proj-A/`，于是手动改对应 `.tour` 内的 `projectRoot` 字段为 `"~/code/proj-A"`。
4. `:CodeTourStart` 即可使用。无需改任何 step 内的 `file` 路径。

---

## Task 0: 初始化项目骨架与测试基础设施

**Files:**
- Create: `~/projects/codetour.nvim/.gitignore`
- Create: `~/projects/codetour.nvim/stylua.toml`
- Create: `~/projects/codetour.nvim/lua/codetour/init.lua`
- Create: `~/projects/codetour.nvim/tests/minimal_init.lua`
- Create: `~/projects/codetour.nvim/tests/smoke_spec.lua`
- Create: `~/projects/codetour.nvim/README.md`

### Step 0.1：创建项目根并初始化 git

Run:
```bash
mkdir -p ~/projects/codetour.nvim/{lua/codetour,plugin,tests/fixtures}
cd ~/projects/codetour.nvim && git init
```

Expected: 出现 `Initialized empty Git repository in ...codetour.nvim/.git/`

### Step 0.2：写 `.gitignore`

Create `~/projects/codetour.nvim/.gitignore`：

```
*.swp
.DS_Store
/tags
```

### Step 0.3：写 `stylua.toml`（与用户主项目保持一致）

Run:
```bash
cp ~/.config/nvim/stylua.toml ~/projects/codetour.nvim/stylua.toml 2>/dev/null || true
```

如果上一步没复制（源文件不存在），创建文件内容：

```toml
column_width = 120
line_endings = "Unix"
indent_type = "Spaces"
indent_width = 2
quote_style = "AutoPreferDouble"
```

### Step 0.4：写最小 `init.lua` 占位

Create `lua/codetour/init.lua`：

```lua
local M = {}

M.version = "0.1.0"

M.config = {
  tours_dir = vim.fn.stdpath("data") .. "/codetour/tours",
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
end

return M
```

### Step 0.5：写测试启动文件 `tests/minimal_init.lua`

```lua
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.runtimepath:append(plenary_path)
vim.opt.runtimepath:append(vim.fn.getcwd())
vim.cmd("runtime plugin/plenary.vim")
```

> 备注：用户的 plenary.nvim 已被 LazyVim 装在 `~/.local/share/nvim/lazy/plenary.nvim`。`stdpath("data")` 在 Mac 上正是 `~/.local/share/nvim`。

### Step 0.6：写第一个冒烟测试 `tests/smoke_spec.lua`

```lua
describe("codetour", function()
  it("loads as a module", function()
    local codetour = require("codetour")
    assert.is_table(codetour)
    assert.equals("0.1.0", codetour.version)
  end)

  it("default tours_dir resolves to stdpath(data)/codetour/tours", function()
    local expected = vim.fn.stdpath("data") .. "/codetour/tours"
    assert.equals(expected, require("codetour").config.tours_dir)
  end)

  it("setup() merges user opts", function()
    require("codetour").setup({ tours_dir = "/tmp/custom-tours" })
    assert.equals("/tmp/custom-tours", require("codetour").config.tours_dir)
  end)
end)
```

### Step 0.7：跑冒烟测试

Run（注意 cwd 在项目根）：
```bash
cd ~/projects/codetour.nvim && \
  nvim --headless --noplugin -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"
```

Expected: 末尾出现 `Success: 3 | Failed : 0 | Errors : 0`。

### Step 0.8：写最小 README 占位

Create `README.md`：

```markdown
# codetour.nvim

Neovim port of the VSCode CodeTour extension.

Status: WIP. See `~/.config/nvim/docs/plans/2026-05-29-codetour-nvim.md` for the implementation plan.
```

### Step 0.9：首次 commit

Run:
```bash
cd ~/projects/codetour.nvim && git add . && git commit -m "chore: 项目骨架与冒烟测试"
```

---

## Task 1: util 模块（路径、JSON、git ref）

**Files:**
- Create: `lua/codetour/util.lua`
- Create: `tests/util_spec.lua`

### Step 1.1：先写失败测试 `tests/util_spec.lua`

```lua
local util = require("codetour.util")

describe("util.expand_path", function()
  it("expands ~ to HOME", function()
    assert.equals(vim.env.HOME .. "/foo", util.expand_path("~/foo"))
  end)
  it("returns absolute paths unchanged", function()
    assert.equals("/abs/x", util.expand_path("/abs/x"))
  end)
end)

describe("util.relative_to", function()
  it("returns slash-separated path relative to a given root", function()
    assert.equals("a/b.lua", util.relative_to("/root/a/b.lua", "/root"))
    assert.equals("a/b.lua", util.relative_to("/root/a/b.lua", "/root/"))
  end)

  it("returns nil when path is not under root", function()
    assert.is_nil(util.relative_to("/other/x", "/root"))
  end)

  it("expands ~ in root before comparing", function()
    local home_file = vim.env.HOME .. "/codetour-test.txt"
    assert.equals("codetour-test.txt", util.relative_to(home_file, "~"))
  end)
end)

describe("util.read_json / write_json", function()
  local tmp = vim.fn.tempname() .. ".json"

  it("writes pretty json with 2-space indent and trailing newline", function()
    util.write_json(tmp, { title = "T", steps = { { line = 1 } } })
    local content = table.concat(vim.fn.readfile(tmp), "\n") .. "\n"
    assert.matches('^{\n  "title": "T",\n  "steps": %[\n    {\n      "line": 1\n    }\n  %]\n}\n$', content)
  end)

  it("reads json back into a table", function()
    util.write_json(tmp, { a = 1, b = "x" })
    local data = util.read_json(tmp)
    assert.equals(1, data.a)
    assert.equals("x", data.b)
  end)

  it("returns nil + error string for bad json", function()
    vim.fn.writefile({ "not json" }, tmp)
    local data, err = util.read_json(tmp)
    assert.is_nil(data)
    assert.is_string(err)
  end)
end)

describe("util.git_ref", function()
  it("returns nil outside a git repo", function()
    local ref = util.git_ref("/")
    assert.is_nil(ref)
  end)

  it("returns current ref string inside the codetour.nvim repo", function()
    local ref = util.git_ref(vim.fn.getcwd())
    assert.is_string(ref)
    assert.is_truthy(#ref > 0)
  end)
end)
```

### Step 1.2：跑测试确认全部失败

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/util_spec.lua"`

Expected: `module 'codetour.util' not found`

### Step 1.3：实现 `expand_path` 和 `relative_to`

Create `lua/codetour/util.lua`：

```lua
local M = {}

local function normalize(p)
  return (p:gsub("\\", "/"))
end

function M.expand_path(p)
  if p:sub(1, 1) == "~" then
    return vim.env.HOME .. p:sub(2)
  end
  return p
end

function M.relative_to(abs_path, root)
  abs_path = normalize(abs_path)
  root = normalize(M.expand_path(root))
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  if abs_path:sub(1, #root) == root then
    return abs_path:sub(#root + 1)
  end
  return nil
end

return M
```

### Step 1.4：跑测试，前 5 条应通过

Expected: `Success: 5 | Failed : 4`（json 4 条 + git 2 条还没实现，已通过 1 条 returns_nil_outside_repo 因 module 已加载）

### Step 1.5：实现 pretty JSON encoder（保持字段顺序）

VSCode CodeTour 文件字段顺序固定。为避免每次保存乱序，需要按"已知 key 顺序 + 其余 key 字典序"输出。`projectRoot` 作为本插件扩展字段，放在 `description` 之后、`ref` 之前（语义上是 tour 元信息）。

往 `util.lua` 追加：

```lua
local TOUR_KEY_ORDER = {
  "$schema", "title", "description", "projectRoot",
  "ref", "isPrimary", "nextTour", "when", "steps",
}

local STEP_KEY_ORDER = {
  "file", "uri", "directory", "view", "contents", "language",
  "line", "pattern", "selection", "title", "description", "commands", "ref",
}

local function ordered_keys(tbl, hint)
  local seen = {}
  local out = {}
  for _, k in ipairs(hint or {}) do
    if tbl[k] ~= nil then
      table.insert(out, k)
      seen[k] = true
    end
  end
  local rest = {}
  for k, _ in pairs(tbl) do
    if type(k) == "string" and not seen[k] then
      table.insert(rest, k)
    end
  end
  table.sort(rest)
  for _, k in ipairs(rest) do
    table.insert(out, k)
  end
  return out
end

local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  if vim.tbl_isempty(t) then
    return getmetatable(t) and getmetatable(t).__jsontype == "array"
  end
  for k, _ in pairs(t) do
    if type(k) ~= "number" then
      return false
    end
  end
  return true
end

local function encode(value, depth, key_hint)
  local pad = string.rep("  ", depth)
  local pad_in = string.rep("  ", depth + 1)
  local t = type(value)
  if t == "nil" then
    return "null"
  elseif t == "boolean" or t == "number" then
    return tostring(value)
  elseif t == "string" then
    return vim.json.encode(value)
  elseif t == "table" then
    if is_array(value) then
      if #value == 0 then
        return "[]"
      end
      local parts = {}
      for i, v in ipairs(value) do
        parts[i] = pad_in .. encode(v, depth + 1, STEP_KEY_ORDER)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "]"
    end
    local keys = ordered_keys(value, key_hint)
    if #keys == 0 then
      return "{}"
    end
    local parts = {}
    for _, k in ipairs(keys) do
      table.insert(parts, pad_in .. vim.json.encode(k) .. ": " .. encode(value[k], depth + 1))
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. pad .. "}"
  end
  error("cannot encode type " .. t)
end

function M.encode_pretty(tbl)
  return encode(tbl, 0, TOUR_KEY_ORDER) .. "\n"
end

function M.write_json(path, tbl)
  local content = M.encode_pretty(tbl)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(content)
  fd:close()
end

function M.read_json(path)
  local fd = io.open(path, "r")
  if not fd then
    return nil, "file not found: " .. path
  end
  local content = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok then
    return nil, data
  end
  return data
end
```

### Step 1.6：跑测试，应再通过 3 条 json 测试

Expected: `Success: 8 | Failed : 1`（git_ref 还没实现）

### Step 1.7：实现 `git_ref`

往 `util.lua` 追加：

```lua
function M.git_ref(cwd)
  local res = vim.system(
    { "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" },
    { text = true }
  ):wait()
  if res.code ~= 0 then
    return nil
  end
  local ref = vim.trim(res.stdout or "")
  if ref == "" then
    return nil
  end
  return ref
end
```

### Step 1.8：跑测试

Expected: `Success: 9 | Failed : 0 | Errors : 0`

### Step 1.9：commit

```bash
git add . && git commit -m "feat(util): 路径展开/相对化、JSON 读写、git ref"
```

---

## Task 2: loader 模块（扫描全局 tours 目录、解析、校验、写回）

**Files:**
- Create: `lua/codetour/loader.lua`
- Create: `tests/fixtures/tours/sample.tour`
- Create: `tests/loader_spec.lua`

### Step 2.1：准备 fixture `tests/fixtures/tours/sample.tour`

> 注意：fixture 的 `projectRoot` 指向 codetour.nvim 项目自身，因为我们要让 step 跳转能找到真实文件。运行测试时 cwd 是 `~/projects/codetour.nvim`，`vim.fn.getcwd()` 即等于这个值。

```json
{
  "$schema": "https://aka.ms/codetour-schema",
  "title": "Sample Tour",
  "description": "A tour for tests",
  "projectRoot": "~/projects/codetour.nvim",
  "ref": "main",
  "steps": [
    {
      "file": "lua/codetour/init.lua",
      "line": 1,
      "title": "Entry",
      "description": "Module entry"
    },
    {
      "contents": "Standalone note",
      "description": "Just a note"
    },
    {
      "directory": "lua/codetour",
      "description": "All source"
    }
  ]
}
```

### Step 2.2：写失败测试 `tests/loader_spec.lua`

```lua
local loader = require("codetour.loader")
local util = require("codetour.util")

local FIXTURE_TOURS = vim.fn.getcwd() .. "/tests/fixtures/tours"

describe("loader.discover", function()
  it("scans the configured tours_dir non-recursively for *.tour", function()
    local tours = loader.discover(FIXTURE_TOURS)
    assert.equals(1, #tours)
    assert.matches("sample%.tour$", tours[1])
  end)

  it("returns empty list for nonexistent dir without throwing", function()
    assert.same({}, loader.discover("/nonexistent/dir"))
  end)
end)

describe("loader.load", function()
  it("parses a tour file and attaches source path", function()
    local tour = loader.load(FIXTURE_TOURS .. "/sample.tour")
    assert.equals("Sample Tour", tour.title)
    assert.equals("~/projects/codetour.nvim", tour.projectRoot)
    assert.equals(3, #tour.steps)
    assert.equals(FIXTURE_TOURS .. "/sample.tour", tour._path)
  end)

  it("rejects when steps missing", function()
    local tmp = vim.fn.tempname() .. ".tour"
    util.write_json(tmp, { title = "Bad", projectRoot = "/x" })
    local tour, err = loader.load(tmp)
    assert.is_nil(tour)
    assert.matches("steps", err)
  end)

  it("rejects when projectRoot missing", function()
    local tmp = vim.fn.tempname() .. ".tour"
    util.write_json(tmp, { title = "Bad", steps = {} })
    local tour, err = loader.load(tmp)
    assert.is_nil(tour)
    assert.matches("projectRoot", err)
  end)
end)

describe("loader.save", function()
  it("writes a tour back, dropping internal _path field", function()
    local tour = loader.load(FIXTURE_TOURS .. "/sample.tour")
    local tmp = vim.fn.tempname() .. ".tour"
    tour._path = tmp
    loader.save(tour)
    local raw = table.concat(vim.fn.readfile(tmp), "\n")
    assert.is_falsy(raw:find("_path"))
    assert.matches('"%$schema"', raw)
    assert.matches('"projectRoot"', raw)
    -- field order: title before projectRoot, projectRoot before steps
    local pos_title = raw:find('"title"')
    local pos_root = raw:find('"projectRoot"')
    local pos_steps = raw:find('"steps"')
    assert.is_truthy(pos_title < pos_root and pos_root < pos_steps)
  end)
end)
```

### Step 2.3：跑测试，全部失败

Run: `nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedFile tests/loader_spec.lua"`

Expected: `module 'codetour.loader' not found`

### Step 2.4：实现 loader

Create `lua/codetour/loader.lua`：

```lua
local util = require("codetour.util")

local M = {}

function M.discover(tours_dir)
  local tours = {}
  local fd = vim.uv.fs_scandir(tours_dir)
  if not fd then
    return tours
  end
  while true do
    local name, t = vim.uv.fs_scandir_next(fd)
    if not name then
      break
    end
    if t == "file" and name:sub(-5) == ".tour" then
      table.insert(tours, tours_dir .. "/" .. name)
    end
  end
  table.sort(tours)
  return tours
end

local function validate(tour)
  if type(tour.title) ~= "string" or tour.title == "" then
    return "missing title"
  end
  if type(tour.projectRoot) ~= "string" or tour.projectRoot == "" then
    return "missing projectRoot"
  end
  if type(tour.steps) ~= "table" then
    return "missing steps array"
  end
  return nil
end

function M.load(path)
  local data, err = util.read_json(path)
  if not data then
    return nil, err
  end
  err = validate(data)
  if err then
    return nil, err
  end
  data._path = path
  return data
end

function M.save(tour)
  assert(tour._path, "tour._path is required for save()")
  local copy = vim.deepcopy(tour)
  copy._path = nil
  util.write_json(tour._path, copy)
end

function M.project_root_abs(tour)
  return util.expand_path(tour.projectRoot)
end

return M
```

### Step 2.5：跑测试

Expected: `Success: 6 | Failed : 0 | Errors : 0`

### Step 2.6：commit

```bash
git add . && git commit -m "feat(loader): 全局 tours 目录扫描、解析、校验、写回"
```

---

## Task 3: state 模块（当前 tour/step + 事件总线）

**Files:**
- Create: `lua/codetour/state.lua`
- Create: `tests/state_spec.lua`

### Step 3.1：写失败测试 `tests/state_spec.lua`

```lua
local state = require("codetour.state")

describe("codetour.state", function()
  before_each(function()
    state.reset()
  end)

  it("starts with no active tour", function()
    assert.is_nil(state.active_tour())
    assert.is_nil(state.active_step())
  end)

  it("set_active_tour stores tour and resets step to 1", function()
    local tour = { title = "T", steps = { { line = 1 }, { line = 2 } } }
    state.set_active_tour(tour)
    assert.equals(tour, state.active_tour())
    assert.equals(1, state.active_step_index())
    assert.equals(tour.steps[1], state.active_step())
  end)

  it("set_step_index clamps and emits :step_changed", function()
    local tour = { title = "T", steps = { { line = 1 }, { line = 2 } } }
    state.set_active_tour(tour)
    local seen = {}
    state.on("step_changed", function(idx)
      table.insert(seen, idx)
    end)
    state.set_step_index(2)
    state.set_step_index(99) -- clamp to 2
    state.set_step_index(0) -- clamp to 1
    assert.same({ 2, 2, 1 }, seen)
  end)

  it("end_tour clears state and emits :tour_ended", function()
    local tour = { title = "T", steps = { { line = 1 } } }
    state.set_active_tour(tour)
    local ended = false
    state.on("tour_ended", function()
      ended = true
    end)
    state.end_tour()
    assert.is_nil(state.active_tour())
    assert.is_true(ended)
  end)
end)
```

### Step 3.2：跑测试确认失败

### Step 3.3：实现 state

Create `lua/codetour/state.lua`：

```lua
local M = {}

local _tour = nil
local _step_idx = nil
local _listeners = {}

function M.reset()
  _tour = nil
  _step_idx = nil
  _listeners = {}
end

function M.on(event, cb)
  _listeners[event] = _listeners[event] or {}
  table.insert(_listeners[event], cb)
end

local function emit(event, ...)
  for _, cb in ipairs(_listeners[event] or {}) do
    cb(...)
  end
end

function M.active_tour()
  return _tour
end

function M.active_step_index()
  return _step_idx
end

function M.active_step()
  if not _tour or not _step_idx then
    return nil
  end
  return _tour.steps[_step_idx]
end

function M.set_active_tour(tour)
  _tour = tour
  _step_idx = 1
  emit("tour_started", tour)
  emit("step_changed", _step_idx)
end

function M.set_step_index(i)
  if not _tour then
    return
  end
  i = math.max(1, math.min(#_tour.steps, i))
  _step_idx = i
  emit("step_changed", i)
end

function M.end_tour()
  local prev = _tour
  _tour = nil
  _step_idx = nil
  emit("tour_ended", prev)
end

return M
```

### Step 3.4：跑测试

Expected: `Success: 4 | Failed : 0`

### Step 3.5：commit

```bash
git add . && git commit -m "feat(state): 当前 tour/step + 事件总线"
```

---

## Task 4: marks 模块（当前 step 行内 extmark）

**Files:**
- Create: `lua/codetour/marks.lua`
- Create: `tests/marks_spec.lua`

### Step 4.1：写失败测试 `tests/marks_spec.lua`

```lua
local marks = require("codetour.marks")

describe("codetour.marks", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line1", "line2", "line3" })
    marks.clear_all()
  end)

  it("set places virt_text on a 1-based line", function()
    marks.set(bufnr, 2, "▶ 1/3")
    local ns = marks.namespace()
    local got = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    assert.equals(1, #got)
    assert.equals(1, got[1][2]) -- 0-based row 1 == line 2
    local virt = got[1][4].virt_text
    assert.equals("▶ 1/3", virt[1][1])
  end)

  it("clear_all removes all marks", function()
    marks.set(bufnr, 1, "x")
    marks.clear_all()
    local ns = marks.namespace()
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
  end)
end)
```

### Step 4.2：跑测试确认失败

### Step 4.3：实现 marks

Create `lua/codetour/marks.lua`：

```lua
local M = {}

local NS = vim.api.nvim_create_namespace("codetour.marks")
local _tracked_bufs = {}

function M.namespace()
  return NS
end

function M.set(bufnr, line_1based, label)
  local row = line_1based - 1
  vim.api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
    sign_text = "▶",
    sign_hl_group = "DiagnosticInfo",
    virt_text = { { label, "DiagnosticInfo" } },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
  _tracked_bufs[bufnr] = true
end

function M.clear_all()
  for buf, _ in pairs(_tracked_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
    end
  end
  _tracked_bufs = {}
end

return M
```

### Step 4.4：跑测试

Expected: `Success: 2 | Failed : 0`

### Step 4.5：commit

```bash
git add . && git commit -m "feat(marks): extmark 行内步骤指示"
```

---

## Task 5: ui 模块（浮动窗口显示 step description）

**Files:**
- Create: `lua/codetour/ui.lua`
- Create: `tests/ui_spec.lua`

### Step 5.1：写失败测试 `tests/ui_spec.lua`

```lua
local ui = require("codetour.ui")

describe("codetour.ui", function()
  after_each(function()
    ui.close()
  end)

  it("show() opens a floating window with markdown buffer", function()
    ui.show({
      title = "1/3 · Entry",
      body = "Module **entry**",
    })
    local winid = ui.winid()
    assert.is_truthy(winid)
    assert.is_true(vim.api.nvim_win_is_valid(winid))
    local bufnr = vim.api.nvim_win_get_buf(winid)
    assert.equals("markdown", vim.bo[bufnr].filetype)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    assert.equals("Module **entry**", lines[1])
  end)

  it("close() destroys window", function()
    ui.show({ title = "x", body = "y" })
    ui.close()
    assert.is_nil(ui.winid())
  end)

  it("show() reuses the existing window/buffer when called twice", function()
    ui.show({ title = "a", body = "b1" })
    local first = ui.winid()
    ui.show({ title = "a", body = "b2" })
    assert.equals(first, ui.winid())
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(first), 0, -1, false)
    assert.equals("b2", lines[1])
  end)
end)
```

### Step 5.2：跑测试确认失败

### Step 5.3：实现 ui

Create `lua/codetour/ui.lua`：

```lua
local M = {}

local _win, _buf

local function ensure_buf()
  if _buf and vim.api.nvim_buf_is_valid(_buf) then
    return _buf
  end
  _buf = vim.api.nvim_create_buf(false, true)
  vim.bo[_buf].buftype = "nofile"
  vim.bo[_buf].bufhidden = "wipe"
  vim.bo[_buf].filetype = "markdown"

  vim.keymap.set("n", "<CR>", function()
    require("codetour.ui").activate_link_under_cursor()
  end, { buffer = _buf, nowait = true })

  vim.keymap.set("n", "q", function()
    require("codetour.runner").end_tour()
  end, { buffer = _buf, nowait = true })

  vim.keymap.set("n", "n", function()
    require("codetour.runner").next()
  end, { buffer = _buf, nowait = true })

  vim.keymap.set("n", "p", function()
    require("codetour.runner").prev()
  end, { buffer = _buf, nowait = true })

  return _buf
end

local function ensure_win()
  if _win and vim.api.nvim_win_is_valid(_win) then
    return _win
  end
  local buf = ensure_buf()
  local cols = vim.o.columns
  local rows = vim.o.lines
  local width = math.max(40, math.floor(cols * 0.4))
  local height = math.max(8, math.floor(rows * 0.3))
  _win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "SE",
    row = rows - 2,
    col = cols - 2,
    width = width,
    height = height,
    border = "rounded",
    title = " CodeTour ",
    title_pos = "left",
    style = "minimal",
    focusable = true,
  })
  vim.wo[_win].wrap = true
  vim.wo[_win].linebreak = true
  return _win
end

function M.winid()
  if _win and vim.api.nvim_win_is_valid(_win) then
    return _win
  end
  return nil
end

function M.show(opts)
  local win = ensure_win()
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_config(win, { title = " " .. (opts.title or "CodeTour") .. " " })
  vim.bo[buf].modifiable = true
  local lines = vim.split(opts.body or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.close()
  if _win and vim.api.nvim_win_is_valid(_win) then
    vim.api.nvim_win_close(_win, true)
  end
  _win = nil
  if _buf and vim.api.nvim_buf_is_valid(_buf) then
    vim.api.nvim_buf_delete(_buf, { force = true })
  end
  _buf = nil
end

function M.activate_link_under_cursor()
  local win = M.winid()
  if not win then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local row, col = unpack(vim.api.nvim_win_get_cursor(win))
  local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local links = require("codetour.markdown").extract_links(line)
  for _, l in ipairs(links) do
    if l.range and col + 1 >= l.range[1] and col + 1 <= l.range[2] then
      if l.kind == "step_ref" then
        require("codetour.runner").goto_step(l.step)
        return
      end
    end
  end
  for _, l in ipairs(links) do
    if l.kind == "shell" and line:match("^%s*>>") then
      vim.cmd("split | terminal " .. l.command)
      return
    end
    if l.kind == "command" then
      vim.notify("CodeTour: command link not bound: " .. l.command, vim.log.levels.WARN)
      return
    end
  end
end

return M
```

### Step 5.4：跑测试

> 注：`activate_link_under_cursor` 依赖未来 Task 7 的 `markdown` 模块；本任务测试只覆盖 show/close/reuse 路径，不会触发链接逻辑。

Expected: `Success: 3 | Failed : 0`

### Step 5.5：commit

```bash
git add . && git commit -m "feat(ui): 浮动窗口 + 浮窗内快捷键 (n/p/q/<CR>)"
```

---

## Task 6: runner 模块（start/next/prev/end/goto，基于 projectRoot 跳转）

**Files:**
- Create: `lua/codetour/runner.lua`
- Create: `tests/runner_spec.lua`

### Step 6.1：写失败测试 `tests/runner_spec.lua`

```lua
local runner = require("codetour.runner")
local state = require("codetour.state")
local marks = require("codetour.marks")

local PROJECT = vim.fn.getcwd()

local function make_tour()
  return {
    title = "Test",
    projectRoot = PROJECT,
    _path = vim.fn.tempname() .. ".tour",
    steps = {
      { file = "lua/codetour/init.lua", line = 3, description = "step1" },
      { contents = "Just text", description = "step2" },
      { file = "lua/codetour/util.lua", line = 1, description = "step3" },
    },
  }
end

describe("codetour.runner", function()
  before_each(function()
    state.reset()
    marks.clear_all()
  end)

  it("start() opens projectRoot+file at the right line", function()
    runner.start(make_tour())
    assert.equals(1, state.active_step_index())
    assert.matches("lua/codetour/init%.lua$", vim.api.nvim_buf_get_name(0))
    local row = vim.api.nvim_win_get_cursor(0)[1]
    assert.equals(3, row)
  end)

  it("next() to a content step does NOT change file buffer", function()
    runner.start(make_tour())
    local before = vim.api.nvim_buf_get_name(0)
    runner.next()
    assert.equals(2, state.active_step_index())
    assert.equals(before, vim.api.nvim_buf_get_name(0))
  end)

  it("next() then next() jumps to util.lua line 1", function()
    runner.start(make_tour())
    runner.next()
    runner.next()
    assert.equals(3, state.active_step_index())
    assert.matches("lua/codetour/util%.lua$", vim.api.nvim_buf_get_name(0))
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("prev() at step 1 stays at step 1", function()
    runner.start(make_tour())
    runner.prev()
    assert.equals(1, state.active_step_index())
  end)

  it("end_tour() clears state and marks", function()
    runner.start(make_tour())
    runner.end_tour()
    assert.is_nil(state.active_tour())
  end)

  it("goto_step(n) jumps directly", function()
    runner.start(make_tour())
    runner.goto_step(3)
    assert.equals(3, state.active_step_index())
  end)

  it("works regardless of current cwd (uses tour.projectRoot)", function()
    local original = vim.fn.getcwd()
    vim.cmd("cd /tmp")
    runner.start(make_tour())
    assert.matches("lua/codetour/init%.lua$", vim.api.nvim_buf_get_name(0))
    vim.cmd("cd " .. original)
  end)
end)
```

### Step 6.2：跑测试确认失败

### Step 6.3：实现 runner

Create `lua/codetour/runner.lua`：

```lua
local state = require("codetour.state")
local marks = require("codetour.marks")
local ui = require("codetour.ui")
local loader = require("codetour.loader")

local M = {}

local function open_file_step(tour, step)
  local root = loader.project_root_abs(tour)
  local path = root .. "/" .. step.file
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  local line = step.line or 1
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd("normal! zz")
  marks.clear_all()
  marks.set(bufnr, line, M._progress_label())
end

local function refresh()
  local tour = state.active_tour()
  local step = state.active_step()
  if not (tour and step) then
    ui.close()
    marks.clear_all()
    return
  end
  if step.file then
    open_file_step(tour, step)
  else
    marks.clear_all()
  end
  local title = string.format(
    "%d/%d · %s%s",
    state.active_step_index(),
    #tour.steps,
    step.title or tour.title,
    step.directory and (" · 📁 " .. step.directory) or (step.contents and " · 📝" or "")
  )
  local body = step.description or step.contents or ""
  ui.show({ title = title, body = body })
end

function M._progress_label()
  return string.format("▶ %d/%d", state.active_step_index() or 0, #(state.active_tour() and state.active_tour().steps or {}))
end

function M.start(tour)
  state.set_active_tour(tour)
  refresh()
end

function M.next()
  state.set_step_index((state.active_step_index() or 0) + 1)
  refresh()
end

function M.prev()
  state.set_step_index((state.active_step_index() or 0) - 1)
  refresh()
end

function M.goto_step(n)
  state.set_step_index(n)
  refresh()
end

function M.end_tour()
  ui.close()
  marks.clear_all()
  state.end_tour()
end

return M
```

### Step 6.4：跑测试

Expected: `Success: 7 | Failed : 0`

### Step 6.5：commit

```bash
git add . && git commit -m "feat(runner): 基于 projectRoot 跳转，无关 cwd"
```

---

## Task 7: markdown 解析（步骤引用 + shell + command 链接）

**Files:**
- Create: `lua/codetour/markdown.lua`
- Create: `tests/markdown_spec.lua`

### Step 7.1：写失败测试 `tests/markdown_spec.lua`

```lua
local md = require("codetour.markdown")

describe("codetour.markdown.extract_links", function()
  it("extracts a step ref [#3]", function()
    local out = md.extract_links("see [#3] for details")
    assert.equals(1, #out)
    assert.equals("step_ref", out[1].kind)
    assert.equals(3, out[1].step)
  end)

  it("extracts a labeled step ref [label][#2]", function()
    local out = md.extract_links("[click here][#2]")
    assert.equals(1, #out)
    assert.equals("step_ref", out[1].kind)
    assert.equals(2, out[1].step)
    assert.equals("click here", out[1].label)
  end)

  it("extracts a shell command line >> npm test", function()
    local out = md.extract_links(">> npm test")
    assert.equals(1, #out)
    assert.equals("shell", out[1].kind)
    assert.equals("npm test", out[1].command)
  end)

  it("extracts a command link [Run](command:foo.bar)", function()
    local out = md.extract_links("[Run](command:foo.bar)")
    assert.equals(1, #out)
    assert.equals("command", out[1].kind)
    assert.equals("foo.bar", out[1].command)
  end)

  it("returns empty for plain text", function()
    assert.same({}, md.extract_links("plain *bold* text"))
  end)
end)
```

### Step 7.2：跑测试确认失败

### Step 7.3：实现 markdown

Create `lua/codetour/markdown.lua`：

```lua
local M = {}

local function find_all(text, pattern, build)
  local out = {}
  local init = 1
  while true do
    local s, e, c1, c2 = text:find(pattern, init)
    if not s then
      break
    end
    table.insert(out, build(s, e, c1, c2))
    init = e + 1
  end
  return out
end

function M.extract_links(text)
  local out = {}

  for _, l in ipairs(find_all(text, "%[([^%]]+)%]%[#(%d+)%]", function(s, e, label, step)
    return { kind = "step_ref", label = label, step = tonumber(step), text = text:sub(s, e), range = { s, e } }
  end)) do
    table.insert(out, l)
  end

  for _, l in ipairs(find_all(text, "%[#(%d+)%]", function(s, e, step)
    return { kind = "step_ref", step = tonumber(step), text = text:sub(s, e), range = { s, e } }
  end)) do
    local covered = false
    for _, o in ipairs(out) do
      if o.range[1] <= l.range[1] and o.range[2] >= l.range[2] then
        covered = true
        break
      end
    end
    if not covered then
      table.insert(out, l)
    end
  end

  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local cmd = line:match("^%s*>>%s*(.+)$")
    if cmd then
      table.insert(out, { kind = "shell", command = cmd })
    end
  end

  for label, cmd in text:gmatch("%[([^%]]+)%]%(command:([^%)]+)%)") do
    table.insert(out, { kind = "command", label = label, command = cmd })
  end

  table.sort(out, function(a, b)
    return (a.range and a.range[1] or 0) < (b.range and b.range[1] or 0)
  end)
  return out
end

return M
```

### Step 7.4：跑测试

Expected: `Success: 5 | Failed : 0`

### Step 7.5：commit

```bash
git add . && git commit -m "feat(markdown): 解析 [#N] / >>cmd / command: 链接"
```

---

## Task 8: 浮窗交互联通测试（回车跳转 step ref）

**Files:**
- Create: `tests/ui_interact_spec.lua`

> ui.lua 的 `activate_link_under_cursor` 已在 Task 5 中写好。本任务只补一个端到端测试，验证 ui+markdown+runner 三者打通。

### Step 8.1：写测试 `tests/ui_interact_spec.lua`

```lua
local ui = require("codetour.ui")
local runner = require("codetour.runner")
local state = require("codetour.state")

describe("codetour.ui interaction", function()
  before_each(function()
    state.reset()
  end)

  it("invokes runner.goto_step when cursor sits on a step ref", function()
    runner.start({
      title = "T",
      projectRoot = vim.fn.getcwd(),
      _path = vim.fn.tempname() .. ".tour",
      steps = {
        { contents = "intro", description = "go to [#2]" },
        { contents = "two", description = "" },
      },
    })
    vim.api.nvim_set_current_win(ui.winid())
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ui.winid()), 0, -1, false)
    local line_idx
    for i, l in ipairs(lines) do
      if l:find("%[#2%]") then
        line_idx = i
        break
      end
    end
    assert.is_truthy(line_idx)
    local col = lines[line_idx]:find("%[#2%]") - 1
    vim.api.nvim_win_set_cursor(ui.winid(), { line_idx, col })
    ui.activate_link_under_cursor()
    assert.equals(2, state.active_step_index())
  end)
end)
```

### Step 8.2：跑测试

Expected: `Success: 1 | Failed : 0`

### Step 8.3：跑全量回归

Run Section 0.3 的命令。Expected: 累计成功 ~28，failed 0。

### Step 8.4：commit

```bash
git add . && git commit -m "test(ui): 浮窗 [#N] 跳转端到端"
```

---

## Task 9: picker 模块（snacks.picker 选 tour / step）

**Files:**
- Create: `lua/codetour/picker.lua`

> snacks.picker 不易在 headless 测试覆盖，本任务只写运行时模块、不写自动化测试，最后通过 Task 13 手工冒烟覆盖。

### Step 9.1：实现 picker

Create `lua/codetour/picker.lua`：

```lua
local loader = require("codetour.loader")
local runner = require("codetour.runner")

local M = {}

local function load_all()
  local config = require("codetour").config
  local files = loader.discover(config.tours_dir)
  local items = {}
  for _, path in ipairs(files) do
    local tour, err = loader.load(path)
    if tour then
      table.insert(items, {
        text = string.format("%-30s  [%s]", tour.title, tour.projectRoot),
        tour = tour,
      })
    else
      vim.notify("CodeTour: 解析失败 " .. path .. ": " .. err, vim.log.levels.WARN)
    end
  end
  return items
end

function M.pick_tour()
  local items = load_all()
  if #items == 0 then
    vim.notify("CodeTour: tours_dir 下没有 .tour 文件", vim.log.levels.INFO)
    return
  end
  local ok = pcall(require, "snacks.picker")
  if ok then
    require("snacks.picker").pick({
      source = "codetour_tours",
      items = items,
      format = "text",
      confirm = function(picker, item)
        picker:close()
        if item then
          runner.start(item.tour)
        end
      end,
    })
    return
  end
  vim.ui.select(items, {
    prompt = "CodeTour",
    format_item = function(it)
      return it.text
    end,
  }, function(choice)
    if choice then
      runner.start(choice.tour)
    end
  end)
end

function M.pick_step()
  local state = require("codetour.state")
  local tour = state.active_tour()
  if not tour then
    return M.pick_tour()
  end
  local items = {}
  for i, step in ipairs(tour.steps) do
    table.insert(items, {
      text = string.format("%d. %s", i, step.title or step.description or step.file or step.contents or ""),
      idx = i,
    })
  end
  vim.ui.select(items, {
    prompt = "CodeTour Step",
    format_item = function(it)
      return it.text
    end,
  }, function(choice)
    if choice then
      runner.goto_step(choice.idx)
    end
  end)
end

return M
```

### Step 9.2：commit

```bash
git add . && git commit -m "feat(picker): 选 tour / 选 step（显示 projectRoot）"
```

---

## Task 10: recorder（创建 tour、添加 step；自动写 projectRoot）

**Files:**
- Create: `lua/codetour/recorder.lua`
- Create: `tests/recorder_spec.lua`

### Step 10.1：写失败测试 `tests/recorder_spec.lua`

```lua
local recorder = require("codetour.recorder")
local state = require("codetour.state")
local loader = require("codetour.loader")

describe("codetour.recorder", function()
  local tmp_tours_dir
  local tmp_project

  before_each(function()
    state.reset()
    tmp_tours_dir = vim.fn.tempname()
    tmp_project = vim.fn.tempname()
    vim.fn.mkdir(tmp_tours_dir, "p")
    vim.fn.mkdir(tmp_project, "p")
    require("codetour").setup({ tours_dir = tmp_tours_dir })
  end)

  it("new_tour creates a fresh tour file in tours_dir with projectRoot from cwd", function()
    vim.cmd("cd " .. tmp_project)
    local tour = recorder.new_tour({ title = "My Tour", description = "desc" })
    assert.equals("My Tour", tour.title)
    assert.equals(0, #tour.steps)
    assert.matches(tmp_tours_dir .. "/my%-tour%.tour$", tour._path)
    -- projectRoot was captured from cwd as ~-style if under HOME, else absolute
    assert.is_string(tour.projectRoot)
    -- file persisted
    local on_disk = loader.load(tour._path)
    assert.equals("My Tour", on_disk.title)
    assert.equals(tour.projectRoot, on_disk.projectRoot)
  end)

  it("add_step computes file path relative to tour.projectRoot", function()
    vim.cmd("cd " .. tmp_project)
    local tour = recorder.new_tour({ title = "T" })
    -- arrange: open a real file under projectRoot and put cursor on line 3
    local sample = tmp_project .. "/sub/sample.lua"
    vim.fn.mkdir(tmp_project .. "/sub", "p")
    vim.fn.writefile({ "a", "b", "c", "d" }, sample)
    vim.cmd("edit " .. sample)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    recorder.add_step("explain c")
    local refreshed = loader.load(tour._path)
    assert.equals(1, #refreshed.steps)
    assert.equals("sub/sample.lua", refreshed.steps[1].file)
    assert.equals(3, refreshed.steps[1].line)
    assert.equals("explain c", refreshed.steps[1].description)
  end)

  it("add_step rejects buffer outside projectRoot", function()
    vim.cmd("cd " .. tmp_project)
    recorder.new_tour({ title = "T" })
    -- open a file outside projectRoot
    local outside = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "x" }, outside)
    vim.cmd("edit " .. outside)
    local ok, err = pcall(recorder.add_step, "should fail")
    assert.is_false(ok)
    assert.matches("outside projectRoot", err)
  end)
end)
```

### Step 10.2：跑测试确认失败

### Step 10.3：实现 recorder

Create `lua/codetour/recorder.lua`：

```lua
local util = require("codetour.util")
local loader = require("codetour.loader")
local state = require("codetour.state")

local M = {}

local function slugify(s)
  return s:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
end

local function tilde_compress(abs)
  local home = vim.env.HOME
  if abs:sub(1, #home) == home then
    return "~" .. abs:sub(#home + 1)
  end
  return abs
end

function M.new_tour(opts)
  local config = require("codetour").config
  local cwd = vim.fn.getcwd()
  local tour = {
    ["$schema"] = "https://aka.ms/codetour-schema",
    title = opts.title,
    description = opts.description,
    projectRoot = tilde_compress(cwd),
    steps = setmetatable({}, { __jsontype = "array" }),
    _path = config.tours_dir .. "/" .. slugify(opts.title) .. ".tour",
  }
  loader.save(tour)
  state.set_active_tour(tour)
  return tour
end

function M.add_step(description)
  local tour = state.active_tour()
  assert(tour, "no active tour")
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname == "" then
    error("buffer has no file name")
  end
  local rel = util.relative_to(bufname, tour.projectRoot)
  if not rel then
    error(string.format("buffer %s is outside projectRoot %s", bufname, tour.projectRoot))
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local step = {
    file = rel,
    line = row,
    description = description or "",
  }
  table.insert(tour.steps, step)
  loader.save(tour)
  return step
end

function M.delete_step(idx)
  local tour = state.active_tour()
  assert(tour, "no active tour")
  table.remove(tour.steps, idx)
  loader.save(tour)
end

function M.edit_description(idx, new_desc)
  local tour = state.active_tour()
  assert(tour, "no active tour")
  tour.steps[idx].description = new_desc
  loader.save(tour)
end

return M
```

### Step 10.4：跑测试

Expected: `Success: 3 | Failed : 0`

### Step 10.5：commit

```bash
git add . && git commit -m "feat(recorder): 创建 tour 自动写 projectRoot；add_step 计算相对路径"
```

---

## Task 11: 命令注册 + plugin 入口

**Files:**
- Create: `lua/codetour/commands.lua`
- Create: `plugin/codetour.lua`
- Modify: `lua/codetour/init.lua`

### Step 11.1：实现 `commands.lua`

```lua
local M = {}

function M.register()
  local function cmd(name, fn, opts)
    vim.api.nvim_create_user_command(name, fn, opts or {})
  end

  cmd("CodeTourStart", function()
    require("codetour.picker").pick_tour()
  end, { desc = "选择并开始一个 tour" })

  cmd("CodeTourNext", function()
    require("codetour.runner").next()
  end, { desc = "下一步" })

  cmd("CodeTourPrev", function()
    require("codetour.runner").prev()
  end, { desc = "上一步" })

  cmd("CodeTourEnd", function()
    require("codetour.runner").end_tour()
  end, { desc = "退出当前 tour" })

  cmd("CodeTourStep", function()
    require("codetour.picker").pick_step()
  end, { desc = "跳到指定步骤" })

  cmd("CodeTourNew", function(args)
    local title = args.args
    if title == "" then
      title = vim.fn.input("Tour title: ")
    end
    if title == "" then
      return
    end
    local tour = require("codetour.recorder").new_tour({ title = title })
    vim.notify(string.format("CodeTour: 已创建 %s\nprojectRoot=%s", tour._path, tour.projectRoot))
  end, { nargs = "?", desc = "新建 tour（projectRoot 自动取自当前 cwd）" })

  cmd("CodeTourAddStep", function(args)
    local desc = args.args
    if desc == "" then
      desc = vim.fn.input("Step description: ")
    end
    local ok, result = pcall(require("codetour.recorder").add_step, desc)
    if not ok then
      vim.notify("CodeTour: 添加 step 失败：" .. tostring(result), vim.log.levels.ERROR)
      return
    end
    vim.notify("CodeTour: step 已追加 (" .. result.file .. ":" .. result.line .. ")")
  end, { nargs = "?", desc = "把当前光标位置作为 step 加入正在录制的 tour" })

  cmd("CodeTourOpenDir", function()
    local dir = require("codetour").config.tours_dir
    vim.fn.mkdir(dir, "p")
    vim.cmd("edit " .. vim.fn.fnameescape(dir))
  end, { desc = "打开 tours 目录（用于跨设备迁移时手动改 projectRoot）" })
end

return M
```

### Step 11.2：写 `plugin/codetour.lua`

```lua
if vim.g.loaded_codetour then
  return
end
vim.g.loaded_codetour = 1

require("codetour.commands").register()
```

### Step 11.3：升级 `lua/codetour/init.lua`

替换内容：

```lua
local M = {}

M.version = "0.1.0"

M.config = {
  tours_dir = vim.fn.stdpath("data") .. "/codetour/tours",
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  vim.fn.mkdir(M.config.tours_dir, "p")
end

M.start = function(...)
  return require("codetour.runner").start(...)
end
M.next = function()
  return require("codetour.runner").next()
end
M.prev = function()
  return require("codetour.runner").prev()
end
M.end_tour = function()
  return require("codetour.runner").end_tour()
end
M.pick = function()
  return require("codetour.picker").pick_tour()
end

return M
```

### Step 11.4：commit

```bash
git add . && git commit -m "feat: 注册 :CodeTour* 命令、自动建 tours_dir、:CodeTourOpenDir"
```

---

## Task 12: LazyVim 本地接入

**Files:**
- Create: `~/.config/nvim/lua/plugins/codetour.lua`

### Step 12.1：写 LazyVim spec

```lua
return {
  {
    dir = vim.fn.expand("~/projects/codetour.nvim"),
    name = "codetour.nvim",
    cmd = {
      "CodeTourStart",
      "CodeTourNext",
      "CodeTourPrev",
      "CodeTourEnd",
      "CodeTourStep",
      "CodeTourNew",
      "CodeTourAddStep",
      "CodeTourOpenDir",
    },
    keys = {
      { "<leader>ct", "<cmd>CodeTourStart<cr>", desc = "CodeTour: start" },
      { "<leader>cn", "<cmd>CodeTourNext<cr>", desc = "CodeTour: next" },
      { "<leader>cp", "<cmd>CodeTourPrev<cr>", desc = "CodeTour: prev" },
      { "<leader>ce", "<cmd>CodeTourEnd<cr>", desc = "CodeTour: end" },
      { "<leader>cs", "<cmd>CodeTourStep<cr>", desc = "CodeTour: pick step" },
      { "<leader>cN", "<cmd>CodeTourNew<cr>", desc = "CodeTour: new tour" },
      { "<leader>cA", "<cmd>CodeTourAddStep<cr>", desc = "CodeTour: add step" },
      { "<leader>cO", "<cmd>CodeTourOpenDir<cr>", desc = "CodeTour: open tours dir" },
    },
    config = function()
      require("codetour").setup({
        -- 跨设备同步推荐改成云盘路径，例如：
        -- tours_dir = vim.fn.expand("~/Dropbox/codetour-tours"),
      })
    end,
  },
}
```

> 如果 `<leader>c` 与 LazyVim 默认有冲突，which-key 会提示，按需改前缀。

### Step 12.2：手工冒烟

操作：
1. 退出当前所有 nvim 实例。
2. `cd ~/.config/nvim && nvim`。
3. 执行 `:CodeTourNew demo`，输入标题 `demo`。Notify 应显示 `projectRoot=~/.config/nvim`，且 `~/.local/share/nvim/codetour/tours/demo.tour` 文件已生成。
4. 移动光标到任一文件任一行（例如 `lua/config/options.lua` 第 5 行），执行 `:CodeTourAddStep` 输入 `option entry`。
5. `:CodeTourEnd`，再 `:CodeTourStart`，picker 应列出 `demo` 项，右侧显示 `[~/.config/nvim]`。
6. 选中后浮窗弹出，左侧 buffer 跳到 `lua/config/options.lua` 第 5 行，行尾显示 `▶ 1/1`。
7. 测试迁移路径：手工把 `demo.tour` 内 `projectRoot` 改成 `~/projects/codetour.nvim`，再 `:CodeTourStart` 选 `demo`，应跳进 codetour.nvim 项目（同 step.file 在那边不存在，会打开空 buffer——属预期，验证了"换设备只改 projectRoot"的语义）。
8. `:CodeTourOpenDir` 应直接打开 `~/.local/share/nvim/codetour/tours/`。

### Step 12.3：commit（在 nvim 配置仓库）

```bash
cd ~/.config/nvim && git add lua/plugins/codetour.lua && git commit -m "feat(plugins): 接入 codetour.nvim 本地开发版"
```

---

## Task 13: README + 端到端冒烟脚本

**Files:**
- Modify: `~/projects/codetour.nvim/README.md`
- Create: `~/projects/codetour.nvim/tests/e2e_smoke_spec.lua`

### Step 13.1：写 e2e 冒烟测试 `tests/e2e_smoke_spec.lua`

```lua
local loader = require("codetour.loader")
local runner = require("codetour.runner")
local state = require("codetour.state")

describe("e2e: discover → load → start → navigate → end", function()
  it("walks through the fixture tour without errors", function()
    state.reset()
    local files = loader.discover(vim.fn.getcwd() .. "/tests/fixtures/tours")
    assert.equals(1, #files)
    local tour = loader.load(files[1])
    runner.start(tour)
    assert.equals(1, state.active_step_index())
    runner.next()
    runner.next()
    assert.equals(3, state.active_step_index())
    runner.prev()
    assert.equals(2, state.active_step_index())
    runner.end_tour()
    assert.is_nil(state.active_tour())
  end)
end)
```

### Step 13.2：跑全部测试

Run Section 0.3 命令。Expected: `Success: ~30 | Failed : 0 | Errors : 0`。

### Step 13.3：扩写 README

替换 `README.md` 为：

````markdown
# codetour.nvim

Neovim 复刻版 [CodeTour](https://github.com/microsoft/codetour)：通过 `.tour` JSON 文件录制和回放代码导览。文件格式与 VSCode CodeTour 兼容（增加了一个 `projectRoot` 扩展字段）。

## 与 VSCode CodeTour 的差异

| | VSCode CodeTour | codetour.nvim |
|---|---|---|
| `.tour` 文件位置 | 散落在各项目的 `.tours/` 或 `.vscode/tours/` | 集中存放在一个全局 tours 目录 |
| 项目根 | 隐式 = 当前工作区 | 显式 = tour 内 `projectRoot` 字段 |
| 跨设备迁移 | 项目目录跟着代码走 | 整个 tours 目录可独立迁移；只需改 `projectRoot` |

## 功能

- 自动扫描 `tours_dir` 下的 `*.tour` 文件
- 通过 `snacks.picker`（或回退 `vim.ui.select`）选择并启动 tour（picker 显示 `projectRoot`）
- 浮动窗口展示 step 描述（markdown 高亮，treesitter）
- 行内 extmark 指示当前 step（左侧 sign + 行尾 `▶ N/M`）
- 浮窗内快捷键：`n` 下一步 / `p` 上一步 / `q` 退出 / `<CR>` 跳转链接
- 步骤间引用：`[#3]` 与 `[标题][#3]`，浮窗按 `<CR>` 直接跳
- Shell 命令链接：`>> npm test` 浮窗按 `<CR>` 在新 split + terminal 执行
- 录制：`:CodeTourNew <title>` 创建空 tour（自动写入 `projectRoot = 当前 cwd`），`:CodeTourAddStep <desc>` 把当前光标行加入

## 安装（LazyVim）

`~/.config/nvim/lua/plugins/codetour.lua`：

```lua
return {
  {
    dir = vim.fn.expand("~/projects/codetour.nvim"),
    name = "codetour.nvim",
    config = function()
      require("codetour").setup({
        -- 默认: ~/.local/share/nvim/codetour/tours
        -- 跨设备同步推荐改成云盘路径：
        -- tours_dir = vim.fn.expand("~/Dropbox/codetour-tours"),
      })
    end,
  },
}
```

## 命令

| 命令 | 说明 |
|---|---|
| `:CodeTourStart` | 选择并启动一个 tour |
| `:CodeTourNext` | 下一步 |
| `:CodeTourPrev` | 上一步 |
| `:CodeTourEnd` | 退出当前 tour |
| `:CodeTourStep` | 直接跳到某个 step |
| `:CodeTourNew <title>` | 新建 tour（自动写入 `projectRoot = 当前 cwd`） |
| `:CodeTourAddStep <desc>` | 把当前光标行加入正在录制的 tour |
| `:CodeTourOpenDir` | 打开 tours 目录 |

## 跨设备迁移

1. 设备 A：`tours_dir` 配在云盘（如 Dropbox / iCloud / git 仓库）。
2. 自动同步到设备 B。
3. 设备 B 上 `:CodeTourOpenDir` 进入 tours 目录。
4. 对每个 `.tour` 文件，把 `"projectRoot"` 字段改成新设备上对应项目的绝对路径（支持 `~`）。
5. `:CodeTourStart` 选中即可使用。step.file 不需要改。

## tour 文件示例

```json
{
  "$schema": "https://aka.ms/codetour-schema",
  "title": "Onboarding",
  "description": "Project tour for newcomers",
  "projectRoot": "~/work/my-project",
  "steps": [
    {
      "file": "src/main.ts",
      "line": 1,
      "title": "Entry point",
      "description": "Start here. See [#3] for the config loader."
    },
    {
      "contents": "## Notes\nAll modules under `src/`.",
      "description": "Architecture overview"
    },
    {
      "file": "src/config.ts",
      "line": 12,
      "description": "Config loader.\n\n>> npm run build"
    }
  ]
}
```

## 测试

```bash
cd ~/projects/codetour.nvim && \
  nvim --headless --noplugin -u tests/minimal_init.lua \
    -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"
```
````

### Step 13.4：最终 commit

```bash
cd ~/projects/codetour.nvim && git add . && git commit -m "docs: README + e2e 冒烟"
```

---

## 验收清单

- [ ] `cd ~/projects/codetour.nvim && PlenaryBustedDirectory tests/` 全绿（约 30 条 spec）
- [ ] `:CodeTourNew demo` 在默认 tours_dir 下建出含 `projectRoot` 的合法 .tour
- [ ] `:CodeTourStart` 不依赖 cwd 也能正确跳转（启动后改 cwd 仍能 next 到正确文件）
- [ ] picker 列出多个 tour 时能看到各自的 projectRoot
- [ ] 浮窗内 `n / p / q / <CR>` 行为正确
- [ ] 手工修改某个 .tour 的 projectRoot 后，`:CodeTourStart` 跳转目的地随之改变
- [ ] 用 VSCode 打开生成的 `.tour` 不报错（projectRoot 字段被 VSCode 忽略，其他字段正常播放）

---

## Task 14: quickfix 内动态编辑 step（顺序 + depth）

### 目标
在 CodeTour 的 quickfix 窗口里直接通过键位调整 step：上移/下移、depth+1/-1、删除。
调整后立即写回 `.tour` 文件并就地刷新 quickfix（不污染 quickfix history），光标跟随。

### 设计要点

- **新增 `lua/codetour/editor.lua`**：集中放编辑逻辑，依赖 `state.active_tour()`，调用 `loader.save` 持久化，调用 `runner.refresh_quickfix` 重渲染。
- **`runner.refresh_quickfix(tour, new_qf_lnum)`**：相比 `populate_quickfix` 的 `" "`（新建 list），用 `"r"` 模式 + 显式 `id` 在原 list 上 replace items；同时找到 CodeTour 的 qf window，重新 apply 高亮，并把光标移动到 `new_qf_lnum`，且通过 `setqflist({}, "a", { idx = ... })` 同步当前 entry。
- **键位绑定时机**：在 `init.lua` 的 `FileType qf` autocmd 中，判断 `getqflist({title=1})` 前缀是 `CodeTour: ` 才绑定 buffer-local 键位，避免污染普通 quickfix。
- **键位可配置**：`config.qf_keymaps = { move_up = "K", move_down = "J", indent = ">", outdent = "<", delete = "dd" }`。设为 `""` 或 `nil` 即不绑定。
- **行号映射**：第 1 行是 ruler、第 2 行是 header，所以 `step_idx = qf_lnum - 2`；`editor._STEP_OFFSET = 2` 暴露给测试。
- **边界与约束**：
  - 上移：第 1 个 step 不动
  - 下移：最后 1 个 step 不动
  - indent：无上限（用户自己负责树的合理性）
  - outdent：clamp 到 0
  - 操作落在 ruler / header 行：`qf_lnum_to_step_idx` 返回非法值，函数静默 no-op
- **每次操作都立即落盘**（无 debounce），简单直接；几十-几百 step 性能无压力。
- **没有活跃 tour 时**：`vim.notify(WARN)` 后静默返回，不抛错。

### 实施

**Step 14.1**：`runner.lua` 新增 `find_codetour_qf_win` + `refresh_quickfix(tour, new_qf_lnum)`。

**Step 14.2**：新建 `lua/codetour/editor.lua`，导出：
- `move_step_up(qf_lnum)`
- `move_step_down(qf_lnum)`
- `indent_step(qf_lnum)`
- `outdent_step(qf_lnum)`
- `delete_step(qf_lnum)`
- `_STEP_OFFSET`（仅供测试）

**Step 14.3**：`init.lua`：
- `M.config.qf_keymaps` 加默认值
- `FileType qf` autocmd 内追加 `bind_qf_keymaps(args.buf)`，仅对 CodeTour 标题前缀的 list 生效。

**Step 14.4**：`tests/editor_spec.lua` 覆盖：
- move_up：交换、第 1 个 no-op、不增长 quickfix history、qftf 输出反映新顺序
- move_down：交换、最后一个 no-op
- indent：连续 +1，落盘正确
- outdent：从 1→0，再 outdent 仍 0
- delete：persist + 数组长度
- 没有活跃 tour 时调用全部 5 个函数都不抛错

**Step 14.5**：commit
```
cd ~/projects/codetour.nvim && git add . && git commit -m "feat(editor): quickfix 内 K/J 移动 step、>/< 调整 depth、dd 删除; 落盘并就地刷新"
```

### 验收

- [x] `editor_spec.lua` 全绿（10 条）
- [x] 整套测试 50/50 全绿
- [ ] 手工：`:CodeTourStart` → 在 quickfix 中 J/K 上下移动 → `.tour` 文件实时更新，光标跟随
- [ ] 手工：> / < 调整 depth → 树形渲染立即变化
- [ ] 手工：dd 删除当前 step → 列表收缩，光标停在原位置（或下一个）

---

## 后续可做（不在本次范围）

- step 的 `pattern` 字段（用正则定位代码而非死行号，应对 git 漂移）
- step 的 `commands` 数组（VSCode 命令到 nvim 命令的映射表）
- tour 级 `nextTour` 自动跳转
- tour 级 `when` 条件（牵涉 JS 表达式求值，需谨慎）
- 录制时弹出 markdown 编辑 buffer（multi-line 描述）
- picker 按 projectRoot 分组聚合
- tours_dir 子目录扫描（递归）
- 自动检测 projectRoot 不存在并提示编辑
- 与 `gitsigns.nvim` / `neo-tree` 联动（在树上展示 directory step）
