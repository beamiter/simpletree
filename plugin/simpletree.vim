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

def CurrentTreeWidth(): number
  for win in getwininfo()
    if getbufvar(win.bufnr, '&filetype') ==# 'simpletree'
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
# y/Y 始终写入 Vim 无名寄存器；开启后还会尝试 + 寄存器或系统剪贴板工具。
g:simpletree_use_system_clipboard = get(g:, 'simpletree_use_system_clipboard', 1)
# 在目标窗口做水平分屏时是否放到下方（默认 1）。若为 0 则遵循 &splitbelow 或传统行为。
g:simpletree_split_below = get(g:, 'simpletree_split_below', 1)
# 仅在目标按键尚未被用户占用时安装 <leader>e。
g:simpletree_set_default_mapping = get(g:, 'simpletree_set_default_mapping', 1)

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
command! SimpleTreeReveal simpletree#OnRevealActive()
command! SimpleTreeHealth simpletree#Health()
command! SimpleTreeVersion call g:SimpleTreeVersion()
command! SimpleTreeToggleAutoRefresh call g:SimpleTreeToggleAutoRefresh()
command! SimpleTreeToggleAutoFollow call g:SimpleTreeToggleAutoFollow()

nnoremap <silent> <Plug>(simpletree-toggle) <Cmd>SimpleTree<CR>
if g:simpletree_set_default_mapping && maparg('<leader>e', 'n') ==# ''
  nmap <silent> <leader>e <Plug>(simpletree-toggle)
endif

# ---------------- 自动命令 ----------------
augroup SimpleTreeBackend
  autocmd!
  autocmd VimLeavePre * try | call g:SimpleTreeCaptureWidth(true) | call simpletree#Stop() | catch | endtry
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
