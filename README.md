# SimpleTree

SimpleTree 是面向 Vim 9 的异步文件树。它以 Rust 后台扫描目录，在 Vim 侧提供接近图形编辑器 Explorer 的工作区根节点、活动文件跟随、未保存标记、稳定选中、窗口复用和文件操作。

SimpleTree 使用 Vim9 script，当前不支持 Neovim。

## 特性

- Rust 后台异步扫描，目录优先、`.gitignore` 感知，并分块传回大目录结果。
- 协议 v2 能力握手：前端按后台宣告的 `capabilities` 启用扩展特性，旧后台自动降级。
- 文件系统 watch：后台监听已展开目录并推送变更事件，外部改动即时反映到树中；不可用时自动回退 mtime 轮询。
- git status 标记：逐文件状态（修改/暂存/未跟踪/冲突/删除）与目录聚合标记，含符号与配色，可完全自定义或关闭。
- 后台递归搜索：`:SimpleTreeSearch` 支持 substring / fuzzy 匹配，结果流式写入 quickfix。
- 树内过滤（`F`）只显示匹配节点及其祖先；`/` 跳转式查找，`]f` / `[f` 循环匹配。
- `s` 在名称、扩展名、修改时间、体积排序间循环，`gs` 反转顺序；目录始终优先，元数据按需异步获取并随缓存复用。
- 树缓冲区按键全部可通过 `g:simpletree_mappings` 覆盖或禁用。
- `User SimpleTree*` 自动命令事件（打开/关闭/换根/展开/文件操作等），便于第三方集成。
- 后台限制并发扫描数量、合并协议输出 flush，快速展开大量目录时更稳定；watch 下的目录列表带失效信号缓存。
- 每个 tabpage 一个树窗口，共用同一棵树：根目录、展开状态与缓存共享，第二个 tab 几乎零开销，关掉其中一个不影响其他 tab。
- 可折叠的工作区根节点；键盘、方向键和鼠标双击均可操作。
- 自动定位当前编辑文件，并在树中高亮活动项。
- 异步刷新后按路径恢复选中项，减少插入或删除条目造成的光标漂移。
- 已修改但未保存的文件可显示 `●`（事件驱动维护，渲染零开销）。
- 复用最近活动的编辑窗口；需要时可选择目标窗口。
- 新建文件和目录支持 `src/components/Button.tsx` 形式的嵌套相对路径。
- 删除优先使用系统回收站，并阻止删除或重命名工作区根、把目录粘贴到自身等操作。
- 单个不可读条目或非 UTF-8 文件名不再导致整目录失败；后台单请求异常不会拖垮 daemon。
- 后台支持版本输出与 `ping` / `pong` 能力握手，便于安装检查和兼容性诊断。

## 要求

| 组件 | 要求 |
|---|---|
| Vim | Vim 9.0 或更新版本，编译时包含 `+job`、`+channel` 和 `+float` |
| Rust | Rust 1.88 或更新版本及 Cargo，用于从源码构建后台 |
| 安装脚本 | Bash；`install.sh` 目前面向 Linux、macOS 等 Bash 环境 |
| 字体 | Nerd Font 可选；未安装时可关闭图标 |
| 回收站 | Linux 可选 `gio trash` 或 `trash-put`，macOS 可选 `trash` |

在 Vim 中检查必要功能：

```vim
:echo has('job')
:echo has('channel')
:echo has('float')
```

三项都应返回 `1`。检查 Rust：

```sh
rustc --version
cargo --version
```

原生 Windows 安装脚本尚未覆盖。可自行构建后台并通过 `g:simpletree_daemon_path` 指向生成的可执行文件，但这条安装路径目前未验证。

## 安装

### vim-plug

```vim
call plug#begin()
Plug 'beamiter/simpletree', { 'do': './install.sh' }
call plug#end()
```

然后执行 `:PlugInstall`；更新时使用 `:PlugUpdate`。

### Vim 原生 package

```sh
git clone https://github.com/beamiter/simpletree.git \
  ~/.vim/pack/plugins/start/simpletree
~/.vim/pack/plugins/start/simpletree/install.sh
```

`install.sh` 会根据脚本自身的位置查找 `Cargo.toml`，因此可从任意当前目录调用。它使用已提交的 `Cargo.lock`、固定本机 Rust target 和插件内构建目录，不受外部 Cargo target 配置影响。安装前会执行新产物的 `--version` 自检，成功后只原子替换 `lib/simpletree-daemon`，不会删除 `lib/` 中的其他内容。

安装完成后，插件目录必须位于 Vim 的 `runtimepath`。后台优先从每个 runtimepath 条目的 `lib/simpletree-daemon` 查找；开发环境还会回退检查 `target/release/` 和 `target/debug/`。

## 快速开始

```vim
:SimpleTree
:SimpleTree /path/to/project
```

`SimpleTree` 用于打开或关闭树。首次不带参数打开时，有普通文件则默认取该文件所在目录，否则取当前工作目录；会话内已有且锁定的根会继续复用。默认映射是 `<leader>e`，但仅在该按键尚未被占用且 `g:simpletree_set_default_mapping` 为 `1` 时安装。

## 命令

| 命令 | 说明 |
|---|---|
| `:SimpleTree [目录]` | 在当前 tabpage 打开或关闭文件树；可选参数指定根目录 |
| `:SimpleTreeRefresh` | 清空缓存并重新扫描当前树 |
| `:SimpleTreeReveal [path]` | 定位活动文件，或显式定位工作区根内的文件/目录 |
| `:SimpleTreeClose` | 保存当前宽度并关闭当前 tabpage 的树窗口（本 tab 没有则全部关闭） |
| `:SimpleTreeDebug` | 输出窗口、根目录、后台和缓存状态 |
| `:SimpleTreeStats[!]` | 查看渲染耗时、buffer diff 与子树缓存命中；`!` 仅重置计数 |
| `:SimpleTreeHealth` | 检查 Vim 功能、配置范围、后台路径及系统 provider |
| `:SimpleTreeVersion` | 输出当前发现的 Rust 后台版本 |
| `:SimpleTreeToggleAutoRefresh` | 会话内切换自动刷新 |
| `:SimpleTreeToggleAutoFollow` | 会话内切换活动文件跟随 |
| `:SimpleTreeSearch <query>` | 后台递归搜索文件名，结果写入 quickfix（需要 v2 后台） |
| `:SimpleTreeSort [mode]` | 设置或循环 `name` / `extension` / `mtime` / `size` 排序 |
| `:SimpleTreeSortReverse` | 反转当前排序（目录仍保持在文件前） |

`:SimpleTreeStats` 的统计是会话内轻量计数：总渲染次数、最近/最大/平均耗时、
可见行数、实际改写行数与成功的 buffer API 写调用数，以及子树缓存
hit/miss、epoch 失效次数和被丢弃切片数。
读取统计不会触发渲染；`:SimpleTreeStats!` 也不会清缓存或推进 epoch，因此可在
性能排查前后安全取样，不会因为观测动作本身制造一次 cache miss。

`:SimpleTreeReveal path` 的相对路径固定相对于当前 tree root，而不是当前窗口的
`:pwd` / `:lcd`；文件补全与包含空格的路径均可用。定位会异步展开所需祖先，连续
调用时只有最新目标能移动选择。路径必须真实存在，且词法路径和解析符号链接后的
路径及其每一级词法祖先的解析结果都要留在工作区根内，避免符号链接先逃逸再重入；
失败不会改变选择、展开状态或 render epoch。命令补全同样从 tree root 当前层枚举，
不会因为窗口 `:lcd` 或手工输入的外逸 symlink 路径遍历工作区之外。

## 默认按键

以下映射只在 `simpletree` 缓冲区内生效：

| 按键 | 操作 |
|---|---|
| `<CR>` / `o` / 双击 | 打开文件，或展开、折叠目录 |
| `l` / `→` | 展开目录并进入首个子项；文件则打开 |
| `h` / `←` / `<BS>` | 折叠当前目录或最近的已展开祖先 |
| `R` | 刷新 |
| `H` | 切换隐藏文件 |
| `I` | 切换 `.gitignore` 过滤 |
| `q` | 关闭树窗口 |
| `e` | 将当前目录设为根；文件则使用其父目录 |
| `U` | 将根上移一层 |
| `C` | 输入新的根目录 |
| `.` | 使用 Vim 当前工作目录作为根 |
| `d` | 使用当前编辑文件所在目录作为根 |
| `L` | 切换根锁定；默认根处于锁定状态 |
| `c` / `x` / `p` | 复制 / 剪切 / 粘贴当前节点 |
| `a` / `n` | 新建文件 |
| `A` / `N` | 新建目录 |
| `r` | 重命名 |
| `D` | 删除；可用时优先移到回收站 |
| `P` | 预览文件并保持树焦点 |
| `V` / `<C-v>` | 垂直分屏打开 |
| `S` / `<C-x>` | 水平分屏打开 |
| `t` / `<C-t>` | 新标签页打开 |
| `f` | 定位当前活动文件 |
| `y` | 复制文件名到 Vim 无名寄存器，并按配置尝试系统剪贴板 |
| `Y` | 复制绝对路径到 Vim 无名寄存器，并按配置尝试系统剪贴板 |
| `gx` | 用系统默认程序打开 |
| `z` | 折叠根节点下所有目录；可配置 |
| `F` | 过滤已加载节点（空串清除；statusline 显示当前过滤） |
| `/` | 按名称查找并跳转 |
| `]f` / `[f` | 跳到下一个 / 上一个查找匹配 |
| `s` / `gs` | 循环排序模式 / 反转当前排序 |
| `?` | 显示完整快捷键帮助 |

所有树内按键都可通过 `g:simpletree_mappings` 覆盖，例如：

```vim
let g:simpletree_mappings = {'X': 'refresh', 'q': ''}
```

键为按键序列，值为 action 名（见 `:help simpletree-mappings`）；空字符串禁用该键。

根默认锁定；需要使用 `e`、`U`、`C`、`.` 或 `d` 改根时，先按 `L` 解锁。

## 全局映射

插件提供 `<Plug>(simpletree-toggle)`：

```vim
let g:simpletree_set_default_mapping = 0
nmap <silent> <leader>n <Plug>(simpletree-toggle)
```

SimpleTree 不会覆盖已存在的 `<leader>e` 映射。树缓冲区内全部按键都可通过
`g:simpletree_mappings` 覆盖或禁用；`g:simpletree_collapse_all_key` 继续作为折叠全部的兼容别名。

## 配置

在插件加载前设置全局变量。布尔选项使用 `0` 或 `1`。

### 树、根目录与刷新

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `g:simpletree_width` | `45` | 树窗口宽度；加载时限制在 `10..500` |
| `g:simpletree_persist_width` | `1` | 保存手动调整后的宽度 |
| `g:simpletree_width_state_file` | 见下文 | 宽度状态文件 |
| `g:simpletree_width_persist_delay` | `250` | 宽度写盘防抖毫秒数；限制在 `0..5000` |
| `g:simpletree_show_root` | `1` | 显示可折叠的工作区根节点 |
| `g:simpletree_root_locked` | `1` | 初始锁定根目录 |
| `g:simpletree_hide_dotfiles` | `1` | 隐藏点文件 |
| `g:simpletree_git_ignore` | `1` | 遵循 Git ignore 规则 |
| `g:simpletree_page` | `200` | 后台每块返回条目数；限制在 `1..1000` |
| `g:simpletree_sort` | `'name'` | `name` / `extension` / `mtime` / `size`；后两者默认最新/最大优先 |
| `g:simpletree_sort_reverse` | `0` | 反转当前模式的顺序；目录仍始终优先 |
| `g:simpletree_auto_follow` | `1` | 进入普通文件缓冲区时在树中跟随 |
| `g:simpletree_auto_follow_change_root` | `0` | 活动文件在根外时自动切到其目录；根锁定时不生效 |
| `g:simpletree_auto_refresh` | `1` | 自动刷新总开关 |
| `g:simpletree_auto_refresh_on_focus` | `1` | Vim 获得焦点时检查外部变化 |
| `g:simpletree_auto_refresh_on_idle` | `1` | `CursorHold` 时检查外部变化 |
| `g:simpletree_auto_refresh_interval` | `3000` | 空闲刷新最小间隔，毫秒；限制在 `3000..600000` |

### 打开文件与窗口

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `g:simpletree_keep_focus` | `1` | 打开文件后把焦点留在文件窗口；`0` 返回树 |
| `g:simpletree_choose_window` | `1` | 多个候选编辑窗口且无法复用时询问目标 |
| `g:simpletree_split_force_right` | `1` | 创建新的垂直编辑分屏时放到右侧 |
| `g:simpletree_split_below` | `1` | 水平分屏放到目标窗口下方 |
| `g:simpletree_open_on_create` | `1` | 新建文件后立即在编辑区打开 |

### 显示与图标

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `g:simpletree_show_modified` | `1` | 标记已修改但未保存的缓冲区 |
| `g:simpletree_modified_symbol` | `'●'` | 未保存标记 |
| `g:simpletree_use_nerdfont` | `1` | 使用 Nerd Font 图标 |
| `g:simpletree_show_file_icons` | `1` | 按扩展名显示文件图标 |
| `g:simpletree_folder_suffix` | `1` | 目录名称显示斜杠后缀 |
| `g:simpletree_icons` | `{}` | 覆盖目录、文件和加载图标 |
| `g:simpletree_file_icon_map` | `{}` | 按不带点的扩展名覆盖文件图标 |
| `g:simpletree_collapse_all_key` | `'z'` | 树缓冲区内“折叠全部”的按键 |

### git status、watch 与事件

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `g:simpletree_git_status` | `1` | 显示 git 状态标记（需要后台 `git-status` 能力与 git 可执行） |
| `g:simpletree_git_status_symbols` | `{}` | 覆盖状态符号，键为 `M/S/U/C/D` |
| `g:simpletree_use_watcher` | `1` | 使用后台文件系统 watch 推送刷新；`0` 回到 mtime 轮询 |
| `g:simpletree_mappings` | `{}` | 树缓冲区按键覆盖表 `{键: action}`；空字符串禁用 |

git 状态高亮组：`SimpleTreeGitModified`、`SimpleTreeGitStaged`、`SimpleTreeGitUntracked`、`SimpleTreeGitConflict`、`SimpleTreeGitDeleted`，均为 `highlight default link`，可在 colorscheme 中覆盖。

第三方集成可监听 `User` 事件（数据在 `g:simpletree_event`）：

```vim
autocmd User SimpleTreeFileCreated echom 'created: ' .. g:simpletree_event.path
```

事件：`SimpleTreeOpen`、`SimpleTreeClose`、`SimpleTreeRootChanged`、`SimpleTreeNodeOpened`、`SimpleTreeDirExpanded`、`SimpleTreeDirCollapsed`、`SimpleTreeFileCreated`、`SimpleTreeFileDeleted`、`SimpleTreeFileRenamed`、`SimpleTreeGitStatusUpdated`、`SimpleTreeFilterChanged`。

### 文件操作、后台与诊断

| 变量 | 默认值 | 说明 |
|---|---:|---|
| `g:simpletree_use_trash` | `1` | 删除时优先调用系统回收站工具 |
| `g:simpletree_use_system_copy` | `0` | 普通文件复制时优先尝试系统命令，再回退到 Vim 实现 |
| `g:simpletree_use_system_clipboard` | `1` | `y/Y` 写无名寄存器后尝试系统剪贴板 |
| `g:simpletree_daemon_path` | `''` | 后台绝对路径；空值时从 runtimepath 自动查找 |
| `g:simpletree_debug` | `0` | 在 `:messages` 中输出额外诊断 |
| `g:simpletree_set_default_mapping` | `1` | 在 `<leader>e` 空闲时安装默认映射 |

示例：

```vim
let g:simpletree_width = 36
let g:simpletree_width_persist_delay = 500
let g:simpletree_auto_refresh_interval = 10000
let g:simpletree_use_nerdfont = 0
let g:simpletree_root_locked = 0
let g:simpletree_set_default_mapping = 0
```

## 宽度持久化

使用 `<C-w><`、`<C-w>>` 或鼠标调整树宽度后，SimpleTree 会立即更新会话内宽度，并在 `g:simpletree_width_persist_delay` 后写入状态文件。连续调整只写最后一次结果；关闭树或退出 Vim 时会强制写入。

默认状态文件：

- 设置了 `$XDG_STATE_HOME`：`$XDG_STATE_HOME/simpletree/width`
- Unix：`~/.local/state/simpletree/width`
- Windows：`~/vimfiles/simpletree/width`

```vim
let g:simpletree_persist_width = 0
let g:simpletree_width_state_file = expand('~/.vim/simpletree-width')
```

## 后台诊断与协议

```sh
/path/to/simpletree-daemon --version
```

协议模式使用 JSON Lines。客户端可发送：

```json
{"type":"ping","id":1}
```

后台返回 `pong`，其中包含 `protocol_version`（当前为 `2`）、`daemon_version` 和 `capabilities`。

协议 v2 请求：`list`（新增 `meta` 标志返回 size/mtime/is_symlink）、`cancel`、`ping`、`watch` / `unwatch`（目录监听，推送 `fs_event`）、`git_status`（逐文件与目录聚合状态）、`search`（递归文件名搜索，流式 `search_chunk`）。v1 的 `list` / `cancel` 负载保持兼容；旧前端会忽略新事件类型，新前端按 `capabilities` 门控扩展特性，两个方向的滚动升级都安全。

## 文件操作与安全语义

- 工作区根不能在树内被剪切、重命名或删除。
- 新建嵌套名称必须是目标目录内的相对路径；重命名只接受单个安全文件名。
- 目录不能粘贴到自身或自身子目录；检查使用解析符号链接后的真实路径。
- 指向根外的目录链接可以显示，但不能作为新建或粘贴目标。
- Unix 上复制符号链接会强制使用 `cp -a` 保留链接本身；没有安全 provider 时拒绝复制。
- 删除前总会确认；回收站失败后会再次询问是否永久删除。
- 复制、覆盖、移动和重命名使用同目录暂存/备份并在失败时尝试回滚。
- 与源、目标或目录子树关联的未保存缓冲区会阻止破坏性操作。
- `y` 和 `Y` 总会先写入 Vim 无名寄存器。

这些保护降低了失败时的数据丢失风险，但不构成跨平台事务性或崩溃一致性保证。执行破坏性操作前仍建议先 `:wall`，并对重要文件保留版本控制或备份。SimpleTree 目前不提供文件操作撤销。

## 故障排查

### `backend not found`

```sh
/absolute/path/to/simpletree/install.sh
```

然后运行：

```vim
:SimpleTreeVersion
:SimpleTreeHealth
```

后台位于其他位置时：

```vim
let g:simpletree_daemon_path = '/absolute/path/to/simpletree-daemon'
```

### 树中出现 `!` 扫描错误

修复权限、路径或后台问题后按 `R`，或执行 `:SimpleTreeRefresh` 显式重试。扫描错误会暂停该目录的自动重复请求，避免错误重试风暴。

### 图标显示为方块

```vim
let g:simpletree_use_nerdfont = 0
```

### 宽度没有保存

检查 `g:simpletree_width_state_file` 的父目录是否可写；也可把 `g:simpletree_width_persist_delay` 临时设为 `0` 进行同步写入诊断。

### 默认映射没有出现

`<leader>e` 已被占用时，SimpleTree 不会覆盖它。使用 `:nmap <leader>e` 检查现有映射，或直接映射 `<Plug>(simpletree-toggle)`。

## 更多文档

- Vim 内置帮助：`:help simpletree`，源文件见 [`doc/simpletree.txt`](doc/simpletree.txt)
- [变更记录](CHANGELOG.md)
- [贡献指南](CONTRIBUTING.md)
