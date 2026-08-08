vim9script

if exists('g:loaded_simpletree')
  finish
endif
g:loaded_simpletree = 1

# =============================================================
# 宽度持久化
# =============================================================
def DefaultWidthStateFile(): string
  if exists('$XDG_STATE_HOME') && $XDG_STATE_HOME !=# ''
    return expand('$XDG_STATE_HOME/simpletree/width')
  endif
  if has('win32') || has('win64')
    return expand('~/vimfiles/simpletree/width')
  endif
  return expand('~/.local/state/simpletree/width')
enddef

def ClampNumber(value: any, fallback: number, minimum: number, maximum: number): number
  if type(value) != v:t_number
    return fallback
  endif
  return min([maximum, max([minimum, value])])
enddef

def NormalizeSortMode(value: any): string
  if type(value) != v:t_string
    return 'name'
  endif
  var mode = tolower(trim(value))
  return index(['name', 'extension', 'mtime', 'size'], mode) >= 0 ? mode : 'name'
enddef

def NormalizeColumns(value: any): list<string>
  if type(value) != v:t_list
    return []
  endif
  var columns: list<string> = []
  for name in value
    if type(name) == v:t_string && index(['size', 'mtime', 'symlink'], name) >= 0
        && index(columns, name) < 0
      columns->add(name)
    endif
  endfor
  return columns
enddef

def NormalizeFilterMode(value: any): string
  if type(value) != v:t_string
    return 'auto'
  endif
  var mode = tolower(trim(value))
  return index(['auto', 'daemon', 'loaded'], mode) >= 0 ? mode : 'auto'
enddef

def NormalizeFlag(value: any, fallback: number = 0): number
  if type(value) == v:t_number
    return value != 0 ? 1 : 0
  endif
  if type(value) == v:t_bool
    return value ? 1 : 0
  endif
  return fallback
enddef

def LoadPersistedWidth(fallback: number): number
  if !get(g:, 'simpletree_persist_width', 1)
    return fallback
  endif
  var state_file = expand(get(g:, 'simpletree_width_state_file', DefaultWidthStateFile()))
  if state_file ==# '' || !filereadable(state_file)
    return fallback
  endif
  try
    var lines = readfile(state_file, '', 1)
    if len(lines) > 0
      var width = str2nr(trim(lines[0]))
      if width > 0
        return ClampNumber(width, fallback, 10, 500)
      endif
    endif
  catch
  endtry
  return fallback
enddef

var s_last_persisted_width: number = -1
var s_pending_width: number = -1
var s_width_persist_timer: number = 0
var s_last_idle_refresh_time: float = 0.0

# 只看当前 tabpage：同一棵树可以同时显示在多个 tab 里，扫描全部 tabpage
# 会把另一个 tab 里那个窗口的宽度当成用户刚刚设定的偏好持久化下来。
def CurrentTreeWidth(): number
  var tabnr = tabpagenr()
  for win in getwininfo()
    if get(win, 'tabnr', 0) == tabnr && getbufvar(win.bufnr, '&filetype') ==# 'simpletree'
      return get(win, 'width', 0)
    endif
  endfor
  return 0
enddef

def StopWidthPersistTimer()
  if s_width_persist_timer == 0
    return
  endif
  try
    timer_stop(s_width_persist_timer)
  catch
  endtry
  s_width_persist_timer = 0
enddef

def PersistPendingWidth()
  StopWidthPersistTimer()
  var width = s_pending_width
  s_pending_width = -1
  if width <= 0 || width == s_last_persisted_width
    return
  endif

  var state_file = expand(get(g:, 'simpletree_width_state_file', DefaultWidthStateFile()))
  if state_file ==# ''
    return
  endif
  try
    call mkdir(fnamemodify(state_file, ':h'), 'p')
    if writefile([string(width)], state_file) == 0
      s_last_persisted_width = width
    endif
  catch
    if get(g:, 'simpletree_debug', 0)
      echom '[SimpleTree] failed to persist width: ' .. v:exception
    endif
  endtry
enddef

def ScheduleWidthPersist(width: number, force: bool)
  StopWidthPersistTimer()
  s_pending_width = width
  var delay = ClampNumber(get(g:, 'simpletree_width_persist_delay', 250), 250, 0, 5000)
  if force || delay == 0 || !exists('*timer_start')
    PersistPendingWidth()
    return
  endif
  try
    s_width_persist_timer = timer_start(delay, (id) => {
      if s_width_persist_timer == id
        s_width_persist_timer = 0
      endif
      PersistPendingWidth()
    })
  catch
    PersistPendingWidth()
  endtry
enddef

def g:SimpleTreeCaptureWidth(force: bool = false)
  var width = CurrentTreeWidth()
  if width <= 0
    if !force
      return
    endif
    width = ClampNumber(get(g:, 'simpletree_width', 45), 45, 10, 500)
  endif

  # 先同步运行时配置，避免 Render() 再次把手动宽度改回默认值。
  g:simpletree_width = width

  if !get(g:, 'simpletree_persist_width', 1)
    StopWidthPersistTimer()
    s_pending_width = -1
    return
  endif
  if width == s_last_persisted_width
    StopWidthPersistTimer()
    s_pending_width = -1
    return
  endif
  ScheduleWidthPersist(width, force)
enddef

def g:SimpleTreeInstallWidthMappings()
  nnoremap <silent> <buffer> <C-W><lt> <C-W><lt><Cmd>call g:SimpleTreeCaptureWidth()<CR>
  nnoremap <silent> <buffer> <C-W>> <C-W>><Cmd>call g:SimpleTreeCaptureWidth()<CR>
enddef

# =============================================================
# 配置
# =============================================================
g:simpletree_persist_width = get(g:, 'simpletree_persist_width', 1)
g:simpletree_width_state_file = get(g:, 'simpletree_width_state_file', DefaultWidthStateFile())
g:simpletree_width_persist_delay = ClampNumber(get(g:, 'simpletree_width_persist_delay', 250), 250, 0, 5000)
g:simpletree_width = LoadPersistedWidth(ClampNumber(get(g:, 'simpletree_width', 45), 45, 10, 500))
s_last_persisted_width = g:simpletree_width
g:simpletree_hide_dotfiles = get(g:, 'simpletree_hide_dotfiles', 1)
# 是否启用 gitignore 过滤（默认开启；关闭后可看到被 git 忽略的文件）
g:simpletree_git_ignore = get(g:, 'simpletree_git_ignore', 1)
# 后端也会执行同样的边界检查；前端先钳制可避免无效配置进入协议。
g:simpletree_page = ClampNumber(get(g:, 'simpletree_page', 200), 200, 1, 1000)
# 目录始终优先；name/extension 默认升序，mtime/size 默认最新/最大优先。
g:simpletree_sort = NormalizeSortMode(get(g:, 'simpletree_sort', 'name'))
g:simpletree_sort_reverse = NormalizeFlag(get(g:, 'simpletree_sort_reverse', 0))
# 打开文件后保持焦点在文件缓冲区
g:simpletree_keep_focus = get(g:, 'simpletree_keep_focus', 1)
g:simpletree_debug = get(g:, 'simpletree_debug', 0)
g:simpletree_daemon_path = get(g:, 'simpletree_daemon_path', '')
g:simpletree_root_locked = get(g:, 'simpletree_root_locked', 1)
# 自动跟随当前 buffer（默认开启）
g:simpletree_auto_follow = get(g:, 'simpletree_auto_follow', 1)
# 当当前文件不在根目录下时，是否自动切换根到文件所在目录（默认关闭；尊重根锁）
g:simpletree_auto_follow_change_root = get(g:, 'simpletree_auto_follow_change_root', 0)
# 像编辑器侧边栏一样显示可折叠的工作区根节点
g:simpletree_show_root = get(g:, 'simpletree_show_root', 1)
# 显示未保存缓冲区标记
g:simpletree_show_modified = get(g:, 'simpletree_show_modified', 1)
g:simpletree_modified_symbol = get(g:, 'simpletree_modified_symbol', '●')
g:simpletree_show_bookmarks = get(g:, 'simpletree_show_bookmarks', 1)
g:simpletree_bookmark_symbol = get(g:, 'simpletree_bookmark_symbol', '★')
# 批量操作标记（<Space>）的行尾符号。
g:simpletree_mark_symbol = get(g:, 'simpletree_mark_symbol', '✓')
# Where bookmarks persist; defaults under $XDG_STATE_HOME (or ~/.local/state).
g:simpletree_bookmarks_file = get(g:, 'simpletree_bookmarks_file', '')
# 展开集合按根持久化，和宽度/书签同一个目录（state.json）。
g:simpletree_persist_state = NormalizeFlag(get(g:, 'simpletree_persist_state', 1), 1)
g:simpletree_state_file = get(g:, 'simpletree_state_file', '')
# 文件不能无限长：最多记多少个根（按最后保存时间 LRU 淘汰）、每个根多少个目录。
g:simpletree_state_max_roots = ClampNumber(get(g:, 'simpletree_state_max_roots', 20), 20, 0, 1000)
g:simpletree_state_max_dirs = ClampNumber(get(g:, 'simpletree_state_max_dirs', 500), 500, 0, 20000)
# `:SimpleTree` 不带参数时回到上次的根。默认关闭：历史行为是用当前文件所在
# 目录，悄悄改掉它会让"打开一个文件再开树"落在一棵完全不相干的树上。
g:simpletree_restore_last_root = NormalizeFlag(get(g:, 'simpletree_restore_last_root', 0), 0)
# 新建文件后直接在编辑区打开
g:simpletree_open_on_create = get(g:, 'simpletree_open_on_create', 1)
# 删除时优先移到系统回收站（支持 gio/trash-put/trash）
g:simpletree_use_trash = get(g:, 'simpletree_use_trash', 1)
# 自动刷新总开关、触发源与空闲触发最小间隔。
g:simpletree_auto_refresh = get(g:, 'simpletree_auto_refresh', 1)
g:simpletree_auto_refresh_on_focus = get(g:, 'simpletree_auto_refresh_on_focus', 1)
g:simpletree_auto_refresh_on_idle = get(g:, 'simpletree_auto_refresh_on_idle', 1)
g:simpletree_auto_refresh_interval = ClampNumber(get(g:, 'simpletree_auto_refresh_interval', 3000), 3000, 3000, 600000)

# =============================================================
# Nerd Font UI 配置与工具
# =============================================================
# 启用 Nerd Font 图标（若终端/GUI无 Nerd Font，可设为 0）
g:simpletree_use_nerdfont = get(g:, 'simpletree_use_nerdfont', 1)
# 是否为文件显示类型图标
g:simpletree_show_file_icons = get(g:, 'simpletree_show_file_icons', 1)
# 目录是否显示斜杠后缀
g:simpletree_folder_suffix = get(g:, 'simpletree_folder_suffix', 1)
# 图标覆盖（如 {'dir': '', 'dir_open': '', 'file': '', 'loading': ''}）
g:simpletree_icons = get(g:, 'simpletree_icons', {})
# 文件类型图标映射覆盖
g:simpletree_file_icon_map = get(g:, 'simpletree_file_icon_map', {})
# 一键折叠（Collapse All）的快捷键（默认 z，缓冲区内生效）
g:simpletree_collapse_all_key = get(g:, 'simpletree_collapse_all_key', 'z')
# 是否在多窗口时弹出选择目标窗口（默认开启）
g:simpletree_choose_window = get(g:, 'simpletree_choose_window', 1)
g:simpletree_split_force_right = get(g:, 'simpletree_split_force_right', 1)
g:simpletree_use_system_copy = get(g:, 'simpletree_use_system_copy', 0)
# 复制/移动的字节搬运交给后端（需要 fs-ops 能力）。关闭后回到 Vim 内的同步
# 实现，粘贴一个大目录会在整个复制期间冻结编辑器——这正是默认开启的原因。
g:simpletree_async_fs_ops = NormalizeFlag(get(g:, 'simpletree_async_fs_ops', 1), 1)
# y/Y 始终写入 Vim 无名寄存器；开启后还会尝试 + 寄存器或系统剪贴板工具。
g:simpletree_use_system_clipboard = get(g:, 'simpletree_use_system_clipboard', 1)
# 在目标窗口做水平分屏时是否放到下方（默认 1）。若为 0 则遵循 &splitbelow 或传统行为。
g:simpletree_split_below = get(g:, 'simpletree_split_below', 1)
# 仅在目标按键尚未被用户占用时安装 <leader>e。
g:simpletree_set_default_mapping = get(g:, 'simpletree_set_default_mapping', 1)

# =============================================================
# 协议 v2 特性（能力握手后生效；旧后端自动降级）
# =============================================================
# 树中显示 git 状态标记与配色（需要后端 git-status 能力与 git 可执行）
g:simpletree_git_status = get(g:, 'simpletree_git_status', 1)
# 覆盖 git 状态符号，如 {'M': '*', 'U': '?'}
g:simpletree_git_status_symbols = get(g:, 'simpletree_git_status_symbols', {})
# 使用后端文件系统 watch 推送刷新；关闭后回到 mtime 轮询
g:simpletree_use_watcher = get(g:, 'simpletree_use_watcher', 1)
# F 过滤的数据来源：'auto'（有 search 能力就用后端）/'daemon'/'loaded'
# 'loaded' 是历史行为——只看已经展开过的目录，刚打开的树里那等于什么也搜不到
g:simpletree_filter_mode = NormalizeFilterMode(get(g:, 'simpletree_filter_mode', 'auto'))
# 后端过滤一次最多接收多少条命中
g:simpletree_filter_max_results = ClampNumber(get(g:, 'simpletree_filter_max_results', 500), 500, 1, 5000)
# 名字右侧的明细列，取值 'size' / 'mtime' / 'symlink'；空列表关闭
# 开启会让列表请求带上 meta（和按体积/时间排序同一条路径）
g:simpletree_columns = NormalizeColumns(get(g:, 'simpletree_columns', []))
g:simpletree_column_time_format = get(g:, 'simpletree_column_time_format', '%m-%d %H:%M')
g:simpletree_column_sep = get(g:, 'simpletree_column_sep', '  ')
# 树缓冲区按键覆盖表：{键: action}；action 为空字符串表示禁用该键
g:simpletree_mappings = get(g:, 'simpletree_mappings', {})

# =============================================================
# 运行时控制与诊断
# =============================================================
def g:SimpleTreeMaybeAutoRefresh(source: string)
  if !get(g:, 'simpletree_auto_refresh', 1)
    return
  endif

  if source ==# 'focus'
    if !get(g:, 'simpletree_auto_refresh_on_focus', 1)
      return
    endif
    s_last_idle_refresh_time = reltime()->reltimefloat() * 1000.0
    simpletree#AutoRefreshOnFocus()
    return
  endif

  if !get(g:, 'simpletree_auto_refresh_on_idle', 1)
    return
  endif
  var now = reltime()->reltimefloat() * 1000.0
  var interval = ClampNumber(get(g:, 'simpletree_auto_refresh_interval', 3000), 3000, 3000, 600000)
  if s_last_idle_refresh_time > 0.0 && (now - s_last_idle_refresh_time) < interval
    return
  endif
  s_last_idle_refresh_time = now
  simpletree#AutoRefreshOnIdle()
enddef

def g:SimpleTreeToggleAutoRefresh()
  g:simpletree_auto_refresh = get(g:, 'simpletree_auto_refresh', 1) ? 0 : 1
  echo '[SimpleTree] auto refresh: ' .. (g:simpletree_auto_refresh ? 'on' : 'off')
enddef

def g:SimpleTreeToggleAutoFollow()
  g:simpletree_auto_follow = get(g:, 'simpletree_auto_follow', 1) ? 0 : 1
  echo '[SimpleTree] auto follow: ' .. (g:simpletree_auto_follow ? 'on' : 'off')
enddef

def FindBackendForVersion(): string
  var configured = expand(get(g:, 'simpletree_daemon_path', ''))
  if configured !=# '' && executable(configured)
    return configured
  endif

  var binary = (has('win32') || has('win64')) ? 'simpletree-daemon.exe' : 'simpletree-daemon'
  for relative in ['lib/' .. binary, 'target/release/' .. binary, 'target/debug/' .. binary]
    for candidate in globpath(&runtimepath, relative, false, true)
      if executable(candidate)
        return candidate
      endif
    endfor
  endfor
  return ''
enddef

def g:SimpleTreeVersion()
  var backend = FindBackendForVersion()
  if backend ==# ''
    echohl ErrorMsg | echom '[SimpleTree] backend not found; run ./install.sh' | echohl None
    return
  endif
  var output = system(shellescape(backend) .. ' --version')
  if v:shell_error != 0
    echohl ErrorMsg | echom '[SimpleTree] version check failed: ' .. trim(output) | echohl None
    return
  endif
  echo '[SimpleTree] ' .. trim(output)
enddef

def g:SimpleTreeClose()
  g:SimpleTreeCaptureWidth(true)
  simpletree#Close()
enddef

# ---------------- 命令与映射 ----------------
command! -nargs=? -complete=dir SimpleTree simpletree#Toggle(<q-args>)
command! SimpleTreeRefresh simpletree#Refresh()
command! SimpleTreeClose call g:SimpleTreeClose()
command! SimpleTreeDebug call simpletree#DebugStatus()
command! -bang SimpleTreeStats call simpletree#Stats(<bang>0)
command! -nargs=? -complete=customlist,simpletree#CompleteReveal SimpleTreeReveal simpletree#OnRevealCommand(<q-args>)
command! SimpleTreeHealth simpletree#Health()
command! SimpleTreeVersion call g:SimpleTreeVersion()
command! SimpleTreeToggleAutoRefresh call g:SimpleTreeToggleAutoRefresh()
command! SimpleTreeToggleAutoFollow call g:SimpleTreeToggleAutoFollow()
command! -nargs=+ SimpleTreeSearch simpletree#Search(<q-args>)
command! -nargs=? -complete=customlist,simpletree#CompleteSort SimpleTreeSort simpletree#SetSort(<q-args>)
command! SimpleTreeSortReverse simpletree#ToggleSortReverse()
command! -nargs=* -complete=customlist,simpletree#CompleteColumns SimpleTreeColumns simpletree#SetColumns(<q-args>)
command! SimpleTreeRestart call simpletree#Restart()
command! SimpleTreeLog     call simpletree#ShowLog()
command! SimpleTreeBookmarks     call simpletree#OnBookmarkJump()
command! SimpleTreeBookmarkClear call simpletree#BookmarkClear()
command! SimpleTreeMarkClear     call simpletree#OnMarkClear()
command! SimpleTreeStateClear    call simpletree#StateClear()

nnoremap <silent> <Plug>(simpletree-toggle) <Cmd>SimpleTree<CR>
if g:simpletree_set_default_mapping && maparg('<leader>e', 'n') ==# ''
  nmap <silent> <leader>e <Plug>(simpletree-toggle)
endif

# ---------------- 自动命令 ----------------
augroup SimpleTreeBackend
  autocmd!
  # 展开集合和宽度一样，最后一次机会就在这里：:qa 不走 Close()，所以
  # EndFrontendSession() 的那次保存对"退出 Vim"这条路径是够不着的。
  autocmd VimLeavePre * try | call g:SimpleTreeCaptureWidth(true)
        \ | call simpletree#PersistSessionState() | call simpletree#Stop() | catch | endtry
augroup END

augroup SimpleTreeWidthPersistence
  autocmd!
  autocmd FileType simpletree call g:SimpleTreeInstallWidthMappings()
  if exists('##WinResized')
    autocmd WinResized * try | call g:SimpleTreeCaptureWidth() | catch | endtry
  endif
  autocmd WinLeave * if &filetype ==# 'simpletree' |
        \ try | call g:SimpleTreeCaptureWidth() | catch | endtry |
        \ endif
augroup END

augroup SimpleTreeAutoFollow
  autocmd!
  # 进入任意缓冲区后尝试自动跟随；仅在启用时生效
  autocmd BufEnter * if get(g:, 'simpletree_auto_follow', 1) |
        \ try | call simpletree#AutoFollow() | catch | endtry |
        \ endif
augroup END

augroup SimpleTreeDecorations
  autocmd!
  # 缓冲区脏状态变化时只重绘装饰，不重扫文件系统
  autocmd TextChanged,TextChangedI,BufWritePost * try | call simpletree#UpdateDecorations() | catch | endtry
augroup END

augroup SimpleTreeAutoRefresh
  autocmd!
  # 当 Vim 获得焦点时检查外部变化，可独立关闭。
  autocmd FocusGained * try | call g:SimpleTreeMaybeAutoRefresh('focus') | catch | endtry
  # CursorHold 只作为触发器，实际最小间隔由 simpletree_auto_refresh_interval 控制。
  autocmd CursorHold * try | call g:SimpleTreeMaybeAutoRefresh('idle') | catch | endtry
augroup END
