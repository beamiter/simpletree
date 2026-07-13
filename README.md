# SimpleTree

面向 Vim 9 的异步文件树。交互目标接近 VS Code Explorer：工作区根节点、活动文件跟随、未保存状态、稳定选中、编辑器窗口复用，以及更安全的文件操作。

## 特性

- Rust 后台异步扫描，目录优先、忽略规则感知，分块渲染大目录。
- 可折叠的工作区根节点；`h/l`、方向键和鼠标双击均可操作。
- 当前编辑文件自动 reveal，并在树中保持活动项高亮。
- 异步刷新和目录变化时按路径恢复选中项，不因插入/删除行发生光标漂移。
- 已修改但未保存的文件显示 `●`。
- 复用最近活动的编辑窗口；多窗口只在第一次无法判断目标时询问。
- 新建文件支持 `src/components/Button.tsx` 形式的嵌套相对路径。
- 删除优先移到系统回收站；阻止删除/重命名工作区根、目录粘贴到自身等危险操作。
- 自动检测展开目录的外部变化，保留展开状态并增量刷新。

## 安装

需要 Vim 9（含 `+job`）和 Rust 工具链：

```sh
./install.sh
```

脚本会构建 `simpletree-daemon` 并安装到插件目录的 `lib/`。然后确保本目录位于 Vim 的 `runtimepath`。

```vim
Plug 'your-name/simpletree'
```

打开/关闭文件树：

```vim
:SimpleTree
:SimpleTree /path/to/project
```

默认映射为 `<leader>e`。其他命令：

```vim
:SimpleTreeRefresh
:SimpleTreeReveal
:SimpleTreeClose
```

## 常用操作

| 按键 | 操作 |
|---|---|
| `<CR>` / `o` / 双击 | 打开文件，或展开/折叠目录 |
| `l` / `→` | 展开目录并进入首个子项；文件则打开 |
| `h` / `←` / `<BS>` | 折叠目录或最近的展开祖先 |
| `f` | 定位当前编辑文件 |
| `P` | 预览文件并保持树焦点 |
| `V` / `S` / `t` | 垂直分屏、水平分屏、新标签打开 |
| `<C-v>` / `<C-x>` / `<C-t>` | 对应的分屏/标签操作 |
| `a` / `A` | 新建文件 / 文件夹 |
| `r` / `D` | 重命名 / 删除（优先回收站） |
| `c` / `x` / `p` | 复制 / 剪切 / 粘贴 |
| `R` | 刷新 |
| `z` | 折叠根节点下所有目录 |
| `H` / `I` | 切换隐藏文件 / gitignore 过滤 |
| `?` | 完整快捷键帮助 |

## 配置

以下均为默认值，请在加载插件前覆盖：

```vim
let g:simpletree_width = 45
let g:simpletree_show_root = 1
let g:simpletree_auto_follow = 1
let g:simpletree_auto_refresh = 1
let g:simpletree_hide_dotfiles = 1
let g:simpletree_git_ignore = 1
let g:simpletree_show_modified = 1
let g:simpletree_modified_symbol = '●'
let g:simpletree_open_on_create = 1
let g:simpletree_use_trash = 1
let g:simpletree_use_nerdfont = 1
let g:simpletree_show_file_icons = 1
```

回收站支持 Linux 的 `gio trash` / `trash-put` 和 macOS 的 `trash` 命令。不可用时会明确提示永久删除。

若不使用 Nerd Font：

```vim
let g:simpletree_use_nerdfont = 0
```

后台不在默认位置时：

```vim
let g:simpletree_daemon_path = '/absolute/path/to/simpletree-daemon'
```
