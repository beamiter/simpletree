# Changelog

本文件记录 SimpleTree 面向用户的重要变化。

## Unreleased

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
