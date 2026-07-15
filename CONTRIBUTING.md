# Contributing to SimpleTree

感谢你改进 SimpleTree。提交改动前，请先确认问题属于 Vim9 前端、Rust 后台、安装发布或文档中的哪一层，并尽量保持一次提交只解决一类问题。

## 开发环境

- Vim 9.0 或更新版本，包含 `+job`、`+channel` 和 `+float`
- Rust 1.85 或更新版本及 Cargo
- Bash
- 推荐安装 `rustfmt`、Clippy 和 ShellCheck

检查环境：

```sh
vim --version
rustc --version
cargo --version
```

## 仓库结构

- `plugin/simpletree.vim`：配置、命令、全局映射和自动命令
- `autoload/simpletree.vim`：树状态、渲染、交互与 Vim/daemon 通信
- `src/simpletree/simpletree_daemon.rs`：JSON Lines 后台协议和目录扫描
- `install.sh`：构建并安装后台到 `lib/`
- `doc/simpletree.txt`：Vim 内置帮助
- `tests/daemon_protocol.rs`：后台协议与目录扫描回归测试
- `tests/vim_smoke.vim`：Vim9 headless 加载与命令 smoke test
- `tests/vim_integration.vim`：真实 daemon、暂存/备份文件操作、缓冲区安全与关闭竞态回归

仓库中还包含 Spacemacs 主题文件；除非改动明确与该主题相关，请不要把主题变化混入 SimpleTree 功能提交。

## 构建

```sh
cargo build --release --locked
./install.sh
```

`install.sh` 可从任意当前目录调用。它应只替换 `lib/simpletree-daemon`，不得清空整个 `lib/`。

## 提交前检查

至少运行与你的改动相关的检查：

```sh
bash -n install.sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
vim -Nu NONE -n -es -X -i NONE -S tests/vim_smoke.vim
vim -Nu NONE -n -es -X -i NONE -S tests/vim_integration.vim
```

`Cargo.lock` 是后台可执行程序的发布输入；依赖变更时应明确更新并一并评审。不要仅因为当前没有覆盖某条路径的自动测试，就跳过手动验证。

Vim9 最低加载检查：

```sh
vim --clean -Nu NONE -n -es \
  -c 'set rtp^=/absolute/path/to/simpletree' \
  -c 'runtime plugin/simpletree.vim' \
  -c 'call simpletree#GetRoot()' \
  -c 'qa!'
```

安装脚本改动还应从仓库外执行：

```sh
cd /tmp
/absolute/path/to/simpletree/install.sh
```

确认它把后台写入仓库自己的 `lib/`，并保留该目录中的其他文件。

## 手动验收

在专用临时目录中验证文件操作，不要使用包含唯一数据的目录。

- `:SimpleTree` 能打开、关闭，后台缺失时提示可理解。
- 展开、折叠、刷新、隐藏文件和 Git ignore 开关行为正确。
- 打开、预览、水平/垂直分屏和新标签页的焦点符合配置。
- `:SimpleTreeReveal`、自动跟随和未保存标记正确。
- 新建嵌套文件和目录后，树能定位新节点。
- 复制、剪切、粘贴、重命名和删除覆盖成功、取消及失败路径。
- 根节点保护、目录粘贴到自身、`.`/`..` 路径等危险输入被拒绝。
- 回收站可用、不可用和调用失败三种情况都给出准确确认。
- 有未保存缓冲区时，移动、替换、重命名和删除应拒绝继续。
- Nerd Font 开启和关闭时均可读。
- `:SimpleTreeHealth` 和 `:SimpleTreeDebug` 输出可用于定位问题。

同目录暂存、备份和回滚不是跨平台事务性保证，SimpleTree 也没有文件操作撤销。测试破坏性操作前请先保存缓冲区，并使用可丢弃的 fixture。

## 修改后台协议

Vim 与后台通过 stdin/stdout 上的一行一个 JSON 对象通信。协议改动必须同时更新发送方、接收方和文档，并至少覆盖：

- 合法请求与错误请求
- 空目录与大目录
- 目录优先及稳定排序
- 隐藏文件和 Git ignore
- 分块边界与最终 `done`
- 取消、并发请求和后台退出
- 空格、Unicode 及不支持路径的明确行为

后台 stdout 只用于协议事件；诊断信息不得混入 JSON Lines。

## 文档约定

用户可见的命令、按键、配置、默认值或安全行为发生变化时，同时更新：

- `README.md`
- `doc/simpletree.txt`
- `CHANGELOG.md` 的 `Unreleased`

不要在文档中声称尚未实现的功能、平台支持、CI 状态、事务性覆盖或性能数字。

修改 Vim help 后可在临时副本中运行 `:helptags doc` 检查标签；除非发布流程明确需要，不要提交本地生成的 `doc/tags`。

## 提交说明

- 说明用户可见结果和风险，而不只是代码实现。
- 对修复提供最小复现步骤。
- 对文件操作改动说明失败时源、目标和未保存缓冲区分别如何处理。
- 避免提交 `target/`、`lib/`、本地状态文件和编辑器临时文件。
