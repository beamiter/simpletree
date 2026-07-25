# Changelog

本文件记录 SimpleTree 面向用户的重要变化。

## Unreleased

### Changed

- 刷新依赖 lockfile 并重建 daemon；行为无变化。

### Added (0.2.0 protocol v2)

- 协议 v2（`protocol_version = 2`），能力握手驱动：前端 ping 后按 `capabilities` 启用新特性，旧后端自动降级为 v1 行为。
- 文件系统 watch：后端基于 notify 非递归监听已展开目录，200ms 去抖后推送 `fs_event`；前端收到后定点失效缓存并重扫，外部变更无需手动刷新。watch 不可用或单目录失败时自动回退 mtime 轮询。
- git status：后端通过 `git status --porcelain=v2 -z` 返回逐文件状态与目录聚合（优先级 C>M>S>U），带 per-repo 缓存、TTL 与 fs 事件失效。树内以符号加高亮显示（`SimpleTreeGit*` 高亮组、text properties 按行染色），`g:simpletree_git_status`、`g:simpletree_git_status_symbols` 可配。
- 递归搜索下沉到后端：新增 `search` 请求（substring / fuzzy 子序列），流式返回；`:SimpleTreeSearch <query>` 将结果写入 quickfix。
- Entry 元数据：`list` 请求新增 `meta` 标志，返回 `size`、`mtime`、`is_symlink`（默认关闭，负载不变）。
- 树缓冲区按键表驱动：`g:simpletree_mappings` 以 `{键: action}` 覆盖或禁用任意默认键；`g:simpletree_collapse_all_key` 保留为兼容别名。
- User 自动命令事件：`SimpleTree{Open,Close,RootChanged,NodeOpened,DirExpanded,DirCollapsed,FileCreated,FileDeleted,FileRenamed,GitStatusUpdated,FilterChanged}`，数据经 `g:simpletree_event` 传递。
- 树内过滤（默认 `F`）：按名称过滤已加载节点并保留祖先链；跳转式查找（默认 `/`，`]f` / `[f` 循环匹配）。
- 新配置：`g:simpletree_use_watcher`、`g:simpletree_git_status`、`g:simpletree_git_status_symbols`、`g:simpletree_mappings`。

### Changed (0.2.0 protocol v2)

- Rust 后端拆分为 protocol / server / scan / watch / git / search 模块；扫描结果对处于 watch 状态的目录启用带失效信号的缓存。
- 后端健壮性：单个请求 panic 不再终止 daemon；不可读子项降级为 warnings 并跳过（不再整目录失败）；非 UTF-8 文件名以 lossy 名称显示并携带 `non_utf8` 标记。
- 渲染性能：未保存标记改为事件驱动的 path 字典（渲染期零 buffer 查询）；reveal 与活动高亮通过 path→行号映射 O(1) 定位；mtime 轮询与 fs 事件共用同一条定点刷新路径。
- daemon watch 生效时跳过 CursorHold 空闲轮询（FocusGained 兜底保留）。

### Changed

- 窗口宽度持久化改为可配置防抖写入，退出和显式关闭时仍会强制落盘，避免频繁 `WinResized` 触发同步磁盘写入。
- 自动刷新可分别控制焦点触发与空闲触发，并可配置空闲触发最小间隔。
- Rust 后台限制同时执行的目录扫描数量，避免快速展开大量目录时挤占阻塞线程池。
- 后台 stdout 写入会合并队列中的协议记录后再 flush，降低大目录分页输出的系统调用开销。
- 普通文件和目录优先复用扫描器提供的文件类型，仅在符号链接或缺失类型信息时额外读取 metadata。
- `install.sh` 在替换现有后台前先执行新产物的 `--version` 自检。
- 显式 release profile 优化保持注释状态；只有在启动、吞吐和二进制体积基准支持时才应重新启用。
- `install.sh` 现在基于脚本自身目录构建，可从任意当前目录调用。
- 安装时仅替换 `lib/simpletree-daemon`，不再删除整个 `lib/`。
- 安装脚本会明确检查 Cargo、Rust 以及最低 Rust 1.85 版本，并使用已提交的 `Cargo.lock` 锁定依赖。
- 默认 `<leader>e` 仅在按键空闲时安装，并提供 `<Plug>(simpletree-toggle)` 用于自定义映射。
- 树宽配置限制到 `10..500`，后台分块大小限制到 `1..1000`。
- 关闭树会取消定时器和在途请求；旧异步回调不再把已关闭窗口重新打开。
- 活动文件 reveal 严格限制在工作区根内，并能识别点目录祖先。
- 后台会等待已接收请求与 stdout 排空后退出，重复请求 ID 使用代际隔离，扫描错误会关联原请求并停止自动重试风暴。
- 后台分块改为线性消费，避免从 `Vec` 头部反复 `drain` 的二次复杂度。
- 文件复制与覆盖改为同目录暂存和旧目标备份，失败时尝试回滚并报告保留项；剪切优先原子改名，跨文件系统时保留源。
- 移动、替换、重命名和删除会拒绝关联的未保存缓冲区，重命名会拒绝 `.`、`..` 和越界名称；嵌套新建与符号链接也会按解析后的工作区边界检查。

### Added

- 新增 `simpletree-daemon --version`、`--help` 以及 `ping` / `pong` 协议握手，返回协议版本、后台版本和能力列表。
- 新增 `:SimpleTreeVersion`、`:SimpleTreeToggleAutoRefresh` 和 `:SimpleTreeToggleAutoFollow`。
- 新增 `g:simpletree_width_persist_delay`、`g:simpletree_auto_refresh_on_focus`、`g:simpletree_auto_refresh_on_idle` 和 `g:simpletree_auto_refresh_interval`。
- 新增 GitHub Actions CI，覆盖 Shell 语法、Rustfmt、Clippy、Rust 测试和 Vim headless 集成测试。
- 新增 `:SimpleTreeHealth` 环境与后台健康检查。
- 新增 `g:simpletree_set_default_mapping` 配置。
- 新增 `g:simpletree_use_system_clipboard` 配置；`y/Y` 始终写 Vim 无名寄存器，并可尝试系统剪贴板。
- 新增 Rust 后台协议测试，以及 Vim headless smoke/文件操作集成测试。
- 补充完整 README、Vim help、故障排查、安全语义和贡献指南。

## 0.1.0 - 2026-07-13

### Added

- Vim9 文件树前端与 Rust 异步目录扫描后台。
- 目录展开、分块渲染、隐藏文件和 Git ignore 过滤。
- 活动文件跟随、未保存标记与刷新后按路径恢复选中。
- 新建、复制、剪切、粘贴、重命名、删除和系统打开操作。
- 编辑窗口复用、预览、分屏、新标签页和工作区根管理。
- 树宽持久化和 Nerd Font 图标。
