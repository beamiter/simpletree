# Changelog

本文件记录 SimpleTree 面向用户的重要变化。

## Unreleased - 2026-08-16

### 新增：与 SimpleRemote 深度协作的集成面

- 导出 `simpletree#ExternalSelectedPath()`（当前 tab 树窗口光标节点的路径，
  文件或目录；没有则 `''`）、`simpletree#ExternalSelectedNode()`（同一节点的
  `{path, is_dir}` 拷贝）与 `simpletree#ExternalMarkedPaths()`（按路径排序的
  标记集合）。此前外部只能通过 `ExternalDropDirectory()` 拿到目录，文件身份
  丢失；SimpleRemote 用它把选中的本地文件/目录作为 `gu` 上传的默认来源。
- `g:simpletree_mappings` 的值接受 `'call:g:Func'` / `'call:plugin#Func'`：
  按键映射成 `<Cmd>call Func()<CR>`，供别的插件往树里挂自己的动作；这些键会
  列在 `?` 帮助末尾。形状不对的名字和未知 action 一样被丢弃并记日志。
- `simpletree#ExternalSetRoot(path, source, opts)`：`opts.watch` / `opts.git`
  （默认 `true`）只对这一个根关掉后台 watch 与 git status——sshfs 挂载上
  inotify 永远收不到远端改动，git status 每次都走网络——关掉 watch 后空闲
  刷新退回 mtime 轮询。任何别的换根入口都会恢复默认；`:SimpleTreeHealth`
  会说明"disabled for this root by its provider"。
- 定位带 URL 方案的缓冲区（SimpleRemote 虚拟模式的 `remote:///srv/app/x`）：
  `f` / `:SimpleTreeReveal` 先问 `g:SimpleRemoteLocalPath()` 有没有投影到本地
  的可读文件，有就照常定位；没有就触发 `User SimpleTreeRevealForeign`
  （载荷 `{name, path, bufnr, winid}`）交给提供方开自己的树，不再报
  "no active file to reveal" 或悄悄定位到更早的某个本地文件。
  `:SimpleTreeReveal remote:///…` 也不再被拼到根下面。事件在那个缓冲区自己的
  窗口里触发（提供方通常照着"当前缓冲区"决定要打开什么），监听方没有自己开窗口
  时光标回到按键的地方；在事件里再次调用 `:SimpleTreeReveal` 不会递归。
  `d` 键对这类窗口做同样的映射。
- acwrite 窗口（`remote://` 缓冲区）现在也是可复用的编辑窗口：从树里打开
  本地文件落进最近使用的那个窗口，而不是每次被迫在右侧新开分屏；`:SimpleTree`
  从这样的窗口切换、进入这样的窗口时都会把它记为目标窗口。新增
  `g:simpletree_target_buftypes`（默认 `['', 'acwrite']`），设为 `['']`
  回到只认普通缓冲区的旧行为。
- 新增 `tests/vim_external_api.vim` 覆盖以上全部；SimpleRemote 在测试里只以
  桩函数出现，插件不依赖它。

## Unreleased - 2026-08-09

### 修复：两个 Vim 实例不再互相抹掉会话状态

- 状态文件是所有实例共用的，而每个实例只在会话开始时读一次、退出时把整份
  内容写回去。两个窗口开两个项目——最常见的用法——意味着谁后退出，另一个
  记下的每一个根都被抹掉，文件最终收敛成一个根，`g:simpletree_state_max_roots`
  说它能记住 20 个这件事在实践中从来没有发生过。现在保存前重新读一遍文件，
  只替换自己那个根的记录，其余原样留下，上限在合并之后再施加一次。
- 写入改成"同目录临时文件 + `rename`"：此刻正在读这个文件的另一个实例要么
  看到完整的旧内容，要么看到完整的新内容，不会看到写了一半的 JSON。

### 修复：搬运失败时不再吞掉备份路径

- 后台搬运在旧目标已经被挪开之后失败、还原也失败时，回复里带着备份路径，
  但 Vim 侧只在成功分支上报它，失败分支提前返回了。用户的原文件因此停在一个
  点开头的兄弟名字下，而默认的 `g:simpletree_hide_dotfiles` 让它在树里根本
  看不见——没有任何东西再提到过它。现在这条路径在成功和失败两条路上都会报。
- Vim 内同步实现里，复制回滚成功之后不再把那个已经不存在的备份路径留在结果
  里；两条实现现在都由调用方统一提示，不会各喊一次。

### 修复：`:help below` 不再落进 SimpleTree 的文档

- 帮助文件里的 `*word*` 不是强调而是**全局** tag 定义。一处散文里的 `*below*`
  让 `doc/tags` 多出一条 `below`，于是任何装了 SimpleTree 的用户执行
  `:help below` 都会被带到本插件的 git 发现一节。
- 新增 `make doc-tags`（已并入 `make check`）：重新生成一份 tags，拒绝任何
  不以 `simpletree` / `g:simpletree` / `:SimpleTree` / `<Plug>(simpletree`
  开头的 tag，并拒绝一份和帮助正文对不上的 `doc/tags`。

### 测试

- `tests/vim_fsops.vim` 里"被拒绝的搬运结束作业链"一节原来通过
  `getscriptinfo().variables` 直接写剪贴板——那个字典是一份**拷贝**，赋值
  没有落到脚本变量上，于是 `OnPaste()` 在"剪贴板为空"处就返回了，整节永远
  为真。改成走一次真实请求：同时剪切一个目录和它里面的文件（`m` 两下就能
  做到），整批在第一个字节移动之前就计划好，所以第二项的来源在轮到它时已经
  随着第一项被搬走了，守护进程真的会拒绝它。
- 新增 `tests/vim_fsop_failures.vim` 与 `tests/fsop_proxy.py`：后者是真实
  守护进程前面的一层透传代理，按来源文件名伪造三条健康环境下走不到的出口
  ——协议级 `error` 回复、后台带着未答复的搬运死掉、`installed:false` 且带
  备份路径——用来钉住"粘贴链不会挂住"和"备份路径一定被念出来"。
- `tests/vim_session_state.vim` 里那条名叫"LRU 根上限留错了根"的断言只钉住
  了上限本身，没有钉住它名字里的那个顺序：断言执行时当前根之外只剩一个候选，
  名额是零，无论怎么排都全被淘汰。把比较器方向倒过来（改成先淘汰最新的）这
  一节照样为真——`g:simpletree_state_max_roots` 说"丢最久没保存的那个"这件事
  从来没有被验证过。改成先从磁盘塞进三个 `saved_at` 互不相同的旧根，再分两步
  收紧名额，断言具体哪几个根活了下来：现在比较器一倒就红。

## Unreleased - 2026-08-08

### 新增：展开集合与上次的根跨会话保留

- 宽度写在 `$XDG_STATE_HOME/simpletree/width`，书签写在 `bookmarks.json`，
  唯独用户每个会话真正重新手搭一遍的东西——展开了哪些目录——在 `:qa` 时被
  丢掉。重开一个深项目意味着先按八次展开才能开始干活。
- 新增 `g:simpletree_persist_state`（默认 1）与 `g:simpletree_state_file`
  （默认 `.../simpletree/state.json`）。关树、换根和 `VimLeavePre` 时写入，
  一个根在一次会话里第一次被打开时读回。
- 恢复只写 `s_state`：目录内容照常按需扫描，`WatchExpandedDirs()` 自己捡起
  这些目录，和用户手动展开走的是同一条路径——没有额外的一次全量遍历。
- 恢复一个根只做一次。第二次（换根来回切、关了再开）不再读文件，否则用户
  刚刚折叠掉的目录会被文件里的旧状态顶回来。已经不存在、或已经不在这个根
  底下的路径直接丢弃：留着它们会让后面的 `I` 在空气上展开。
- 文件有上限：`g:simpletree_state_max_roots`（默认 20，按 `saved_at` LRU
  淘汰）与 `g:simpletree_state_max_dirs`（默认 500）。超出每根上限时留浅的
  ——深处的一个展开贡献极小，而先丢祖先会让它的后代也显示不出来。正在保存
  的那个根永远不参与淘汰：`localtime()` 只有秒的精度，同一秒里保存的两个根
  按 `saved_at` 排不出先后。
- 新增 `g:simpletree_restore_last_root`（默认 **0**）：`:SimpleTree` 不带
  参数时回到上次的根。默认关闭是因为历史行为是"当前文件所在目录"，悄悄改掉
  它会让"打开一个文件再开树"落在一棵完全不相干的树上。
- 新增 `:SimpleTreeStateClear`，`:SimpleTreeHealth` 多一行 `session state`。
- 新增测试 `tests/vim_session_state.vim`：预置一份状态文件后开树，断言里面
  的目录自己展开了、不在里面的目录仍然折叠、已经消失的目录没有进 `s_state`；
  然后断言保存下来的集合等于屏幕上的形状、换根时旧根先落盘、两个上限、关掉
  开关之后文件一个字节都不变，以及 `:SimpleTreeStateClear` 真的删文件。

### 新增：复制与移动交给后台执行（`fs-ops`）

- 过去复制的每一个字节都由 Vimscript 在主线程上搬：`readblob` 分块读、逐块
  `writefile`、每个目录一次 `readdir`。粘贴一个 `target/` 或 `node_modules/`
  会把编辑器完全冻住——不重绘、不响应 `CTRL-C`、没有进度——直到复制结束，
  而守护进程恰好在这段时间里闲着。现在 `c`/`x` + `p` 每一项发一条 `fs_op`
  请求，`OnPaste()` 立即返回，树随每条回复更新。
- 下放的只有字节搬运。工作区包含性、未保存缓冲区拒绝、冲突提示以及提示之后
  的重新验证（`:help simpletree-safety`）全部留在 Vim 侧：它们依赖守护进程
  看不到的编辑器状态。整批的提问在第一次搬运开始之前一次问完，搬运开始后
  用户不会再被打断，作业也不会建立在一个已经过时的回答上。
- 后台使用与 Vim 实现同样的同目录暂存/备份纪律（`.simpletree-staged-*` →
  `rename` 安装 → 删除 `.simpletree-backup-*`），并且从不跟随符号链接：复制
  出来的链接仍然是链接，因此不再需要 `cp -a`。跨文件系统的移动退回"安装一份
  完整副本并保留源"，和以前一样。
- 作业按标记顺序逐个执行而不是一次全部发出：并发搬运会让失败报告的顺序和
  同名目标的判定都不确定。同一次粘贴里两个同名来源现在会各自被询问——异步
  执行下磁盘上还看不到前一个目标，`PathExists()` 单独判断会让它们互相覆盖。
- 后台在一次搬运中途退出时，等待中的作业会以错误结束并提示，而不是让粘贴链
  静默断在半路（剪贴板与标记停在中间状态）。
- 新增 `g:simpletree_async_fs_ops`（默认 1）。关闭它，或者后台没有宣告
  `fs-ops` 能力时，原来的 Vim 内同步实现原样运行，包括
  `g:simpletree_use_system_copy`。删除与重命名仍在 Vim 内完成：它们是一次
  系统调用，不是一次遍历。
- 新增测试：`tests/daemon_fsops.rs` 覆盖协议形状、被拒绝的复制不碰目标、
  未知 op 变成 error、取消不产生完成事件；`tests/vim_fsops.vim` 断言
  `OnPaste()` 返回时目标"还不存在"（Vim 不会在脚本执行期间跑 channel 回调，
  所以这个断言是确定的，不是靠计时），并断言关闭开关后的同步回退仍然工作。

### 新增：体积 / 修改时间 / 符号链接明细列

- `Entry` 早就带着 `size`、`mtime`、`is_symlink`，`meta` 标志早就流经
  `ScanDirAsync()`，`s_cache_has_metadata` 早就记着哪些快照是"富"的——但这一切
  只喂给排序比较器。于是"按体积排序"可以，"看见体积"不行。
- 新增 `g:simpletree_columns`（`size`/`mtime`/`symlink`，默认空）、
  `g:simpletree_column_time_format`、`g:simpletree_column_sep`，以及
  `:SimpleTreeColumns [size|mtime|symlink|none]`。开启明细列和按体积/时间排序
  走同一条"缺 metadata 才重扫"的逻辑，快照已经够富时不会白扫一次。
- 列插在名字和装饰之间、右对齐到树宽：`●`/`★`/`✓` 的语法匹配全部锚在行尾，
  把列放到它们右边会让那三个高亮整体失效。列本身用文本属性高亮
  （`SimpleTreeColumn`，默认 link 到 `Comment`）——名字里什么字符都可能出现，
  行内正则只能是猜，而渲染期的字节偏移是精确的。
- 树宽只在开了列的时候进入渲染配置签名：没开列的树不该为一次窗口缩放付出整棵
  缓存重算的代价。
- 新增测试：`tests/vim_columns.vim` 覆盖默认关闭、体积格式（`4.0K` / `5B` /
  目录为 `-`）、右对齐后两行等宽、文本属性存在、时间格式可配、关掉之后行尾
  恢复原样、未知列名不改配置。

### 新增：一个根下的多个 git 仓库；根在大仓库内时按子树限定

- `resolve_repo_root()` 只往上走，所以树根是一个"放着若干 checkout 的目录"
  （`~/projects`、`~/work`，任何非 git 的容器）时，它解析不到任何仓库，整棵树
  一个标记都没有——而且失败是看不见的。现在往上找不到就往下找：最多下探 3 层，
  每条分支碰到仓库就停（仓库自己的子目录由它那次 status 覆盖），跳过点开头的
  目录和符号链接，最多 32 个仓库。
- 每个仓库单独回一条事件，前端合并而不是覆盖：过去 `s_git_status` 是整体赋值，
  第二个仓库会把第一个的标记全部顶掉。其中一个仓库失败不影响其他仓库的标记；
  全部失败才作为错误上报。
- 根在一个大仓库*内部*时，status 现在带上根对应的 pathspec。
  `<monorepo>/services/api` 不再在每次保存时对整个 worktree 跑一遍
  `git status --porcelain=v2 -uall`，也不再把上万条无关状态发过协议。
- `.git` 存在不等于是仓库：现在要求它要么是文件（worktree/submodule 指针），
  要么是含 `HEAD` 的目录。此前你项目上方任何一个空的 `.git` 目录都会让所有
  status 查询变成 git 自己那句"not a git repository"，并且报在你的树根上。
- 换根时正在途中的查询会被作废（它算的是旧根下的仓库），
  `:SimpleTreeHealth` 现在报仓库数量而不是最后回复的那一个。
- 新增测试：`tests/daemon_git_multi.rs`（容器目录下发现两个仓库、两张状态图
  不重叠、根在仓库内时按子树限定、完全没有仓库时报错）、`git.rs` 单元测试
  （空 `.git` 不算仓库、发现不重复下探、前缀计算）、`tests/vim_git_multi.vim`
  （前端合并两个仓库、Health 报数量、换根后旧仓库消失）。

### 新增：`F` 过滤走后台递归遍历

- `DirHasFilterMatch()` 明确只走 `s_cache`，也就是用户手动展开过的那部分。
  刚打开一棵树时那部分几乎是空的，于是 `F` + 一个真实存在的文件名什么也找
  不到——看起来像功能坏了，而不像一条有文档的限制。与此同时后台早就有一条
  完整的递归 `search` 请求，结果却只往 quickfix 里写。
- 现在 `F` 用同一条请求：匹配项显示，通往它们的目录显示并在渲染期强制展开。
  强制展开刻意不写进 `s_state`——清掉过滤之后，用户自己的展开状态原样回来。
  子树渲染缓存的有效性判断也跟着改用生效后的展开状态，否则清掉过滤会留下一
  棵被强制展开的缓存子树。
- 结果是流式到达的，每一批都会失效渲染缓存并重绘。状态行里 `filter:{query}`
  后面在结果还没到齐时跟一个 `…`，在遍历撞上上限时跟一个 `(N+)`：这两种情况
  和"就这么多"看起来本来一模一样。重新输入过滤会取消上一次遍历，迟到的分块
  不会把旧结果放回屏幕。显式 `:SimpleTreeRefresh` 会重跑遍历。
- 新增 `g:simpletree_filter_mode`（`auto`/`daemon`/`loaded`，默认 `auto`）与
  `g:simpletree_filter_max_results`（默认 500）。后台没有 `search` 能力时自动
  退回 `loaded`，也就是原来的行为。
- 新增测试：`tests/vim_filter.vim` 过滤一个只存在于从未展开过的目录里的名字
  ——在旧的 loaded 模式下这必然渲染不出任何东西——并断言强制展开没有落到
  `s_state`、被取代的遍历不会把结果放回来、`loaded` 模式仍然可用。

### 修复：一个不可能变红的断言

- `tests/vim_marks.vim` 里"标记集合中有未保存缓冲区"的用例走的是
  `OnDelete()`，而 headless ex 模式下 `confirm()` 永远返回默认的 No，于是
  无论提示之前的 `RefuseModifiedBuffers()` 过滤器在不在，两个文件都会留下。
  这个断言按构造就是绿的，只提供虚假的信心。现在把那层过滤抽成
  `DeletableTargets()` 并由测试直接驱动，同时把同样无法经由提示框观察的
  根目录 / 已消失路径 / 工作区外路径三条守卫一并钉住。

## Unreleased - 2026-08-05

### 修复：`:SimpleTree {dir}` 换根时也清标记、也解 watch

- `Toggle()` 过去直接给 `s_root` 赋值，绕过了 `SetRoot()`，于是"换根会清掉
  标记"（`:help simpletree-marks`）只对树内的 `.`/`d`/`C`/root-up 成立，对
  `:SimpleTree {dir}` 不成立——包括 `:help simpletree-tabpages` 明确推荐的
  "在另一个 tab 里传目录换根"这条路径。结果是换根后 `marked:N` 还挂在状态行
  上，`c`/`x` 复制的是屏幕上根本看不见的旧根路径，光标下明明是个普通文件，
  `D` 却报 "refusing to delete a path that resolves outside the workspace"
  并且什么也没删。现在两条换根路径共用同一段清理。
- 同一处还漏了 `UnwatchAllDirs()`：旧根会一直被 watch 着。顺带修掉
  `WatchExpandedDirs()`——`s_state` 是跨换根保留的，它却不按当前根过滤，
  换根后又把旧根下所有展开过的目录重新 watch 了一遍。
- 无效目录不再先把 `s_root` 写坏再报错：`:SimpleTree /nope` 现在保持原来的根。
- 新增测试：`tests/vim_marks.vim` 覆盖两条换根路径（另一个 tab 里换根、
  关闭后在别处重开），断言标记被清空、状态行不再计数、旧根不再出现在
  `s_watched` 里。

### 修复：搜索的取消与串行化

- 后台：被取消的 `search` 会永久占住一个并发扫描许可。消费端在 `break` 之后
  仍持有 `batch_rx` 就去 `worker.await`，而 walk 线程正卡在容量 4 的
  `blocking_send()` 上——`blocking_send` 只有在接收端被 *drop* 时才报错，于是
  两边互等。取消 8 次之后，整个会话的目录列举全部停止。现在 await 之前先
  `drop(batch_rx)`。新增单元测试用一个不被消费的事件通道稳定复现卡死。
- 前端：两次 `:SimpleTreeSearch` 不再互相覆盖。此前两组回调各自活着，先发的
  那次晚几秒完成时会把用户正在读的 quickfix 整个换掉并重新 `copen`，被放弃的
  遍历还一直占着许可。现在只有最新一次能写结果，新搜索会取消并注销上一次；
  关闭树也会让在途搜索作废。新增 `tests/vim_search.vim`。

### CI：修好门禁本身

- `.github/workflows/ci.yml` 的两处 `dtolnay/rust-toolchain@1.85.0` 提到
  `1.88.0`。`Cargo.toml` 早已声明 `rust-version = "1.88"`，而 cargo 把更高的
  `rust-version` 当作硬错误——`cargo check --locked` 在编译任何东西之前就失败，
  CI 自那以后每一次 push 都是红的，msrv 与主测试作业都没真的跑过。
- 新增一步从 `Cargo.toml` 反推校验：`uses:` 不接受表达式，所以 toolchain 仍是
  字面量，但这一步会把本文件里所有 `dtolnay/rust-toolchain@` 的 pin 和
  `rust-version` 对一遍，不一致就直接失败。旧的 "keep the toolchain here in
  step with rust-version" 注释没能做到这件事。
- CI 里手抄的 Vim 步骤换成一句 `make check`，Makefile 成为"通过"的唯一定义。
  此前 `tests/vim_sorting.vim`、`tests/vim_reveal.vim` 和 `make core-verify`
  （`.simplecore.manifest` 的 sha256 校验，也是它存在的全部意义）从未在 CI 里
  跑过。`bash -n install.sh` 也从 CI 步骤挪进新的 `make shell`，顺带覆盖
  `install-common.sh`。

### `:SimpleTreeHealth` 能回答"为什么不工作了"

- 检测过期的 `lib/simpletree-daemon`：把二进制的 mtime 与仓库里最新的
  `src/**/*.rs`、`Cargo.toml`、`Cargo.lock` 比较，落后就报
  `[!!] backend build: ... — run ./install.sh, then :SimpleTreeRestart`，
  并计入最终的 ready 判定。插件管理器更新了 Vim 侧文件却没重新构建 daemon，
  是这套插件最常见也最难自己看出来的故障。源码不在旁边（从发行包安装）时
  明说无法比较，不猜。
- `git status` 不再从能力位推断出 `active`。`GitStatusRefresh()` 过去发请求
  时不注册回调，而 `DispatchLine()` 只在 `s_bcbs` 里有对应 id 时才分发
  `error`，于是树根不在 git 仓库内、索引损坏这类失败被彻底丢弃——树上没有
  标记，也没有任何解释，Health 还说一切正常。现在每个请求都带回调，Health
  报的是最近一次查询的真实结果，失败时原样带出后台的错误文本；成功事件按
  id 摘除回调，不留下泄漏的关联项。
- 新增 CONTEXT 行：当前会话（打开/关闭、根、树窗口数）、在途扫描与回调数、
  缓存目录数，以及第一个扫描失败的目录及其错误。
- 新增 `tests/vim_health.vim`：树根不在 git 仓库时必须报出后台错误且不得出现
  `git status: active`、失败请求不得泄漏 `s_bcbs` 条目、二进制新旧比较的三种
  结果（旧 / 新 / 无法比较）。

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
