# Changelog

本文件记录 SimpleTree 面向用户的重要变化。

## Unreleased - 2026-08-05

### 新增：标记与批量操作

- `<Space>` 标记/取消标记光标节点并下移一行；可视模式下同一个键按整段选区
  标记（整段已标记时取消），`gm` 标记全部可见同级节点，`gM`（或
  `:SimpleTreeMarkClear`）清空。行尾符号为 `g:simpletree_mark_symbol`（默认
  `✓`），数量进 statusline 的 `marked:N`。
- 有标记时 `c` / `x` / `D` 作用于整个标记集合，否则仍作用于光标节点。剪贴板
  本来就是 `{mode, items: [...]}`、`OnPaste()` 本来就在 `items` 上循环，只是
  一直只装一个元素——这次只是把那条已有的路径喂满。
- 批量删除只弹一次确认（最多列 5 个名字 + `(and N more)`），但确认之后每条
  路径都单独重跑全部破坏性守卫：重新取活的 `getftype()`、工作区包含性、未保存
  缓冲区拒绝；失败项不影响其他项，最后一并报出。删除是唯一一个可能开着提示框
  等任意长时间的操作，这条复验不能因为批量而放宽。
- 工作区根永远不能被标记。换根与粘贴成功后清空标记；刷新（`R`/`H`/`I` 都走
  它）保留标记但丢掉指向已消失路径的那些。
- `mark_toggle` 的可视映射装在与普通模式同一个键上，重绑 `g:simpletree_mappings`
  里的 `mark_toggle` 会把两者一起带走。文档里的 action 清单同时补上了此前漏掉的
  四个书签 action。
- 标记属于行内容，因此每次增删都 `BumpRenderEpoch()`，符号与数量进配置签名；
  `tests/vim_render_cache.vim` 增加对应断言。新增 `tests/vim_marks.vim` 覆盖
  标记、可视选区标记、同级标记、批量复制/移动/删除与逐条守卫复验。

### 修复：多 tabpage 下的树

- 树窗口改为按 tabpage 记录。此前 `s_winid` 是一个全局变量，而 `win_id2win()`
  只在当前 tabpage 里查找：第二个 tab 里 `WinValid()` 恒为假，`:SimpleTree`
  会再开一棵树（而且撞上 `E95: Buffer with this name already exists`，留下一个
  没有 filetype 的空窗口）；随后关掉第一个 tab，那个 buffer 的 `BufWipeout`
  会结束整个前端会话，把还活着的那棵树一起拆掉——树不再响应按键，再按一次
  又开第三棵。
- 现在整棵树只有一个 buffer，同一个 buffer 在各 tab 的窗口里显示：渲染只写
  一次，根目录、展开状态、扫描缓存与 git status 天然共享，第二个 tab 不产生
  额外扫描。`:SimpleTree` 只作用于当前 tabpage；关掉最后一个树窗口才结束会话。
- 会话已经开着时，无参数的 `:SimpleTree` 不再用当前文件重新定根——否则在新
  tab 里打开会把另一个 tab 的视图一起换掉。给已有会话添加窗口也不再递增会话
  代号，避免静默作废在途扫描的回调。
- 活动文件高亮（`matchaddpos()` 是窗口局部的）改为每个树窗口各自维护，别的
  tab 不会停在旧的高亮行上。
- 宽度持久化只测量当前 tabpage 的树窗口，不再把另一个 tab 里那个窗口的宽度
  当成用户刚设定的偏好存下来。
- 新增 `tests/vim_tabpages.vim`：两个 tab 各自开关、在第一个 tab 里 toggle 必须
  关闭而不是再开一棵、关掉一个 tab 后另一个 tab 的树仍然响应 toggle。

### 任意路径定位

- `:SimpleTreeReveal [path]` 现在可显式定位根内文件或目录；相对路径固定以 tree root
  为基准，支持文件补全、空格路径、根节点和根内符号链接，省略参数仍定位活动文件。
- 定位前检查词法 containment，并逐级验证每个祖先的 `resolve()` 结果；不存在、
  经符号链接逃逸或先逃逸再重入的路径，在改动选择、展开状态或 render epoch 前
  即失败。每次定位带单调前端 token，迟到的 scan/timer 只能更新自身缓存，不能
  完成或移动更新的定位目标；已有 partial cache 的在途 scan 也会安全挂接当前 token。
- `SimpleTreeReveal` 的补全改为从 tree root 当前层安全枚举并转义空格；绝对路径、
  父目录和每个候选复用同一 containment 守卫，不会跟随 `:lcd` 或外逸 symlink。

### 可观测渲染性能

- 新增 `:SimpleTreeStats[!]`，会话内报告 Render 次数与最近/最大/平均耗时、可见
  行数、buffer diff 实际改写行数与成功 API 写调用数、子树缓存 hit/miss/命中率、
  epoch 失效次数及丢弃切片数；`:SimpleTreeDebug` 同步给出紧凑摘要。
- 统计读取与 `!` 重置刻意旁路 `BumpRenderEpoch()` 和 `SubtreeValid()`：不会清缓存、
  伪造 hit/miss 或让下一次渲染变慢。禁用缓存生成参照渲染时也不污染命中统计。
- 最大耗时使用显式 Float 比较，不调用 Vim 9.1.1684 才支持的 `max(list<Float>)`；
  计算前也将 `dict<any>` 成员收窄为 Number/Float，避免 Vim 9.0.1108 之前的
  E1012。新增可观测性不改变项目原有 Vim 9.0 最低版本。
- render-cache 回归增加观测透明性断言：查询前后全量状态一致，重置保留 epoch 与
  cache entries，随后相同 Render 必须直接命中且不产生 miss。

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### 本插件

- `--self-test`:在进程内扫描一个真实目录,并检查握手能力。目录遍历是每次
  会话的第一步,也是最依赖 `ignore` crate 真的链接进来的地方。
- `ignore` 升到 0.4.33。此前被 MSRV 卡在旧版本上。

### 新增：多维文件排序

- `:SimpleTreeSort [name|extension|mtime|size]` 与树内 `s` 可直接设置或循环排序，
  `:SimpleTreeSortReverse` / `gs` 反转当前顺序；目录无论正反序都保持在文件前。
- 名称和扩展名默认升序，修改时间和体积默认最新/最大优先。切到后两种模式时
  前端按需请求 daemon 已有的 metadata 字段并重扫，不让常规名称浏览承担额外
  `stat` 开销；metadata 随目录缓存快照记录，同一快照只重扫一次，之后切换四种
  模式直接复用。旧后台缺少字段时稳定回退到名称次序。
- 排序模式进入渲染缓存签名与 statusline，运行时切换不会复用旧子树切片；新增
  `tests/vim_sorting.vim` 覆盖四种模式、反序、目录优先、补全和默认映射，v2
  集成测试另验证首次 metadata 重扫、跨模式缓存复用与真实文件体积顺序。
- 非默认排序不再对每个流式 chunk 重排整个增长中的目录，而在扫描完成时原子发布；
  比较键的小写名/扩展名也改为每项只计算一次，大目录排序不再重复做字符串工作。

### 新增:书签

- `m` 切换光标所在节点的书签,`'` 把全部书签列进 quickfix,`]b` / `[b` 在树内
  可见的书签之间循环(到头会绕回)。命令:`:SimpleTreeBookmarks`、
  `:SimpleTreeBookmarkClear`。
- 书签持久化到 JSON(默认 `$XDG_STATE_HOME/simpletree/bookmarks.json`,可用
  `g:simpletree_bookmarks_file` 指定),重启后仍在。文件就是一个绝对路径数组,
  手工编辑或纳入版本管理都可以。
- 列出书签时会顺手丢掉指向已不存在路径的条目,列表不会越积越多。
- 书签标记与开关:`g:simpletree_bookmark_symbol`(默认 `★`)、
  `g:simpletree_show_bookmarks`。
- 书签标记属于行内容,因此增删书签会 `BumpRenderEpoch()`,符号与开关进入配置
  签名——`tests/vim_render_cache.vim` 增加了对应断言,确认缓存不会渲染出陈旧标记。
- 新增 `tests/vim_bookmarks.vim`:切换、落盘与内存一致、跳转与绕回、清空、命令
  在无书签时不报错。测试使用临时存储文件,不会碰到用户自己的书签。

### 构建与 CI 修复

- `ignore` 锁定回 0.4.27:0.4.30 使用了 let-chains(需要 Rust 1.88),而 CI 与 `rust-version` 都是 1.85,`Lint Rust` 作业自 2026-07-26 起一直失败。
- 修复 `doc/simpletree.txt` 中重复的 help tag(`:SimpleTreeHealth`)。
- 新增 CI 的 MSRV 作业。

### 性能:树渲染

实测环境 19200 个文件、展开到 11700 可见行(每次展开/折叠都会触发一次 Render):

| 阶段 | 每次 Render |
|---|---|
| 优化前 | 63 ms |
| 子树缓存 | 30 ms |
| + path→行号按需构建 | 21 ms |
| + buffer diff 不再回读整个 buffer | **20 ms** |

- 按目录缓存已渲染的行与索引切片:只重建真正变化的子树,其余用 `extend()` 拼接。
  校验分两层——目录列表比对象身份与长度(流式扫描是往同一个 list 追加,只比身份
  会漏),子目录比展开状态并递归;其余状态(git、未保存标记、过滤、配置、根目录)
  统一走 epoch 失效。配置签名每次渲染做一次 O(1) 比对,运行时改图标/后缀不会
  渲染出陈旧内容。
- `path -> 行号` 字典改为按需构建。一次渲染通常只查一次(恢复光标),为此建上万条
  的字典纯属浪费;并且展开光标所在目录时它自己的行号不变,先做 O(1) 校验,命中
  就连字典都不用建。
- buffer diff 以上一次写入的内容为基准,不再每次把上万行读回来;行数对不上时
  退回真读。
- 新增 `tests/vim_render_cache.vim`:每做一次操作(展开、折叠、改未保存状态、
  过滤、改配置、刷新、增删文件)就把 "走缓存" 与 "关缓存重算" 的渲染逐行比对,
  任何漏掉的失效点都会让测试失败。已验证:去掉任意一处 `BumpRenderEpoch()`
  该测试都会捕获。

### 修复

- 后端崩溃后只提示 "press R to retry",在此之前整棵树都不可用;现在会自动退避
  重启,重启后重新握手并补挂 watch 与 git status,树自行恢复。

### 变更

- `:SimpleTreeHealth` 增加监督层状态(存活、协议、崩溃/重启计数、熔断)。

### 可靠性:统一 daemon 监督层 (simplecore)

- 进程生命周期改由 vendored `simplecore` 监督层接管(`autoload/simpletree/core.vim`,
  从 `.simplecore/` 同步,请勿直接编辑)。九个插件共用同一份实现:
  - 存活判定一律走 `job_status()`。`job_start()` 即使 exec 失败也会返回 job
    对象,所以 `job != null` 并不能说明进程还活着。
  - 代际守卫:被替换掉的旧 daemon 的 `exit_cb` 迟到时,不会再清掉接替它的新
    进程的状态。
  - 停止栅栏:显式停止后仍在管道里的事件会被丢弃,不会把刚拆掉的状态又写回去。
  - 指数退避自动重启;同一时间窗内反复崩溃则熔断,只报错一次而不是无限重启。
    手动 `:SimpleTreeRestart` 会重新合闸。
  - 请求按 id 关联并支持超时,卡死的 daemon 不会让回调永远悬着。
- 新增 `:SimpleTreeHealth`、`:SimpleTreeRestart`、`:SimpleTreeLog`,全套插件命名一致。

### 测试

- 新增 `tests/vim_core.vim`:监督层回归套件(存活判定、代际守卫、停止栅栏、
  退避重启、崩溃熔断、请求超时、协议握手、raw/json 两种编解码),由
  `tests/fake_daemon.py` 驱动——一个可以按需应答/静默/乱码/崩溃/忽略 SIGTERM
  的假 daemon。
- 新增 `make defcompile`:强制编译所有 Vim9 `def`。Vim9 惰性编译会把冷分支里的
  语法/类型错误一直藏到用户真正踩中为止。
- `make check` 现在包含以上两项。

## Unreleased

### Changed

- 启用 release 调优（lto、codegen-units=1、strip、panic=abort），依据实测：
  二进制 3.75 MB → 2.06 MB（-45%），启动+ping 往返不变（约 1.7ms），
  113k 文件的 search 遍历 21ms → 20ms。
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
