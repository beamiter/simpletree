vim9script

def NFEnabled(): bool
  return !!get(g:, 'simpletree_use_nerdfont', 0)
enddef

# 图标集合（会根据 NF 状态初始化，并允许 g:simpletree_icons 覆盖）
var s_icons: dict<string> = {}

# 统一的文件类型图标映射（可被 g:simpletree_file_icon_map 覆盖）
var s_file_icon_map: dict<string> = {
  'vim': '', 'lua': '', 'py': '', 'rb': '', 'go': '', 'rs': '',
  'js': '', 'ts': '', 'jsx': '', 'tsx': '',
  'c': '', 'h': '', 'cpp': '', 'hpp': '',
  'java': '', 'kt': '',
  'sh': '', 'bash': '', 'zsh': '',
  'md': '', 'txt': '',
  'json': '', 'toml': '', 'yml': '', 'yaml': '', 'ini': '',
  'lock': '',
  'html': '', 'css': '', 'scss': '',
  'png': '', 'jpg': '', 'jpeg': '', 'gif': '', 'svg': '', 'webp': '',
  'pdf': '',
  'zip': '', 'tar': '', 'gz': '', '7z': ''
}

var s_file_icon_map_ready: bool = false
var s_icon_version: number = 0
var s_cached_syntax_sig: string = ''
var s_cached_syntax_sig_ver: number = -1

def SetupFileIconMap()
  if s_file_icon_map_ready
    return
  endif
  var override = get(g:, 'simpletree_file_icon_map', {})
  if type(override) == v:t_dict
    for [k, v] in items(override)
      s_file_icon_map[k] = v
    endfor
  endif
  s_file_icon_map_ready = true
  s_icon_version += 1
enddef

def SetupIcons()
  if NFEnabled()
    s_icons = {
      dir: '',        # 关闭的目录
      dir_open: '',   # 打开的目录
      file: '',       # 通用文件
      loading: ''     # 加载中
    }
  else
    s_icons = {
      dir: '▸',
      dir_open: '▾',
      file: '  ',
      loading: '⏳'
    }
  endif
  # 允许用户覆盖图标
  for [k, v] in items(get(g:, 'simpletree_icons', {}))
    s_icons[k] = v
  endfor
  s_icon_version += 1
  # 保证文件类型图标映射已加载（供 FileIcon/SetupSyntaxTree 复用）
  SetupFileIconMap()
enddef

# 文件类型图标（常用扩展；未命中时用通用文件图标）
def FileIcon(name: string): string
  if !NFEnabled()
    return s_icons.file
  endif
  var ext = tolower(fnamemodify(name, ':e'))
  if ext ==# ''
    return '󰈙'   # 通用文件（无扩展）
  endif
  return get(s_file_icon_map, ext, s_icons.file)
enddef

call SetupIcons()

# =============================================================
# 前端状态
# =============================================================
var s_bufnr: number = -1
# 当前 tabpage 的树窗口 id。这只是 TreeWin() 维护的备忘,权威状态在 s_tabs;
# 读它的地方一律先过 WinValid()/TreeWin(),否则拿到的是别的 tab 的窗口。
var s_winid: number = 0
var s_root: string = ''
var s_hide_dotfiles: bool = !!g:simpletree_hide_dotfiles
var s_root_locked: bool = !!g:simpletree_root_locked
var s_git_ignore: bool = !!get(g:, 'simpletree_git_ignore', 1)

var s_state: dict<any> = {}               # path -> {expanded: bool}
var s_cache: dict<list<dict<any>>> = {}   # path -> entries[]
var s_cache_has_metadata: dict<bool> = {} # path -> cached list requested meta=true
var s_loading: dict<bool> = {}            # path -> true
var s_loading_has_metadata: dict<bool> = {} # path -> inflight list requested meta=true
var s_scan_errors: dict<string> = {}      # path -> last error; explicit refresh retries
var s_pending: dict<number> = {}          # path -> request id
var s_line_index: list<dict<any>> = []    # 渲染行对应的节点
var s_active_path: string = ''            # 当前编辑器文件（用于活动项装饰）
var s_target_winid: number = 0            # 最近使用的编辑窗口，避免反复询问

# ─────────────────── 每个 tabpage 一个树窗口 ───────────────────
#
# 树窗口曾经是一个全局 s_winid,而 win_id2win() 只在当前 tabpage 里查找:
# 第二个 tab 里 WinValid() 恒为假,于是 Toggle() 又开一棵树,而先关掉的那一棵
# 触发 BufWipeout 时会把还活着的那一棵一起拆掉(见 tests/vim_tabpages.vim)。
#
# 现在窗口按 tabpage 记录,但整棵树只有一个 buffer:同一个 buffer 在多个
# tab 的窗口里显示,渲染仍然只写一次,缓存/展开状态天然共享,第二个 tab 的
# 成本接近零。tabpagenr() 会在关闭 tab 后重排,不能做 key,所以用一个存在
# tabpage 局部变量里的单调 token。
#
# token -> {winid, matchid}；matchid 是 matchaddpos() 的返回值，窗口局部。
var s_tabs: dict<dict<number>> = {}
var s_tab_seq: number = 0

# 渲染节流
var s_render_timer: number = 0

# 剪贴板（复制/剪切）
var s_clipboard: dict<any> = {mode: '', items: []}  # {mode: 'copy'|'cut', items: [paths...]}

# 帮助面板状态
var s_help_winid: number = 0
var s_help_bufnr: number = -1
var s_help_popupid: number = 0      # 浮窗 ID

# Reveal 定位
var s_reveal_target: string = ''
var s_reveal_timer: number = 0
# Monotonic frontend token: an old scan/timer may render cache data, but it
# must never complete a newer reveal or move its selection.
var s_reveal_generation: number = 0
# Directory -> reveal token. A scan that predates the reveal may help only when
# that reveal explicitly registered the directory as one of its ancestors.
var s_reveal_waiting: dict<number> = {}

# 前端窗口生命周期。异步回调必须属于当前打开会话，关闭后的旧回调不能重建窗口。
var s_open: bool = false
var s_session_generation: number = 0

# =============================================================
# 后端状态（合并）
# =============================================================
var s_bnext_id = 0
var s_bcbs: dict<any> = {}   # id -> {OnChunk, OnDone, OnError}

# 协议 v2 能力握手：pong 到达前为空 dict，所有扩展能力按不可用降级。
var s_backend_caps: dict<bool> = {}
var s_backend_protocol: number = 0

# 文件系统 watch（daemon 推送 fs_event；无能力时回退 mtime 轮询）
var s_watched: dict<bool> = {}        # dir -> true（已发出 watch 请求）
var s_watch_failed: dict<bool> = {}   # dir -> true（watch 被拒绝，回退轮询）
var s_fs_pending_dirs: dict<bool> = {}
var s_fs_refresh_timer: number = 0

# git status（daemon 查询；path -> 状态码 M/S/U/C/D，目录为聚合码）。
# json_decode 产物是 dict<any>，保持 any 避免赋值处的类型收窄失败。
var s_git_status: dict<any> = {}
var s_git_repo_root: string = ''
var s_git_timer: number = 0

# 树内过滤：只作用于已加载缓存的节点
var s_filter_query: string = ''
var s_filter_memo: dict<bool> = {}    # dir -> 已加载后代中是否有匹配

# 跳转式查找
var s_find_query: string = ''

# path -> 渲染行号（1-based），reveal/高亮 O(1) 定位
var s_path_lines: dict<number> = {}
# s_line_index 每次渲染递增；s_path_lines 落后时按需重建。
var s_line_index_gen: number = 0
var s_path_lines_gen: number = -1

# path -> 未保存标记；由 UpdateDecorations 事件维护，渲染期只查字典
var s_modified_paths: dict<bool> = {}

# ─────────────────── 书签 ───────────────────
#
# path -> true。持久化到 g:simpletree_bookmarks_file,重启后仍在。
# 书签会改变行内容(行尾多一个标记),所以每次增删都必须 BumpRenderEpoch()。
var s_bookmarks: dict<bool> = {}
var s_bookmarks_loaded: bool = false

# ─────────────────── 排序 ───────────────────
const SORT_MODES = ['name', 'extension', 'mtime', 'size']

def SortMode(): string
  var mode = get(g:, 'simpletree_sort', 'name')
  if type(mode) != v:t_string
    return 'name'
  endif
  mode = tolower(trim(mode))
  return index(SORT_MODES, mode) >= 0 ? mode : 'name'
enddef

def SortNeedsMetadata(mode: string = SortMode()): bool
  return mode ==# 'mtime' || mode ==# 'size'
enddef

# Metadata belongs to a directory-list snapshot, not to the selected sort mode.
# Include inflight scans so a non-metadata refresh cannot replace a rich stale
# cache immediately after SetSort() decides that no refresh is necessary.
def CachedSnapshotsHaveMetadata(): bool
  if empty(s_cache) && empty(s_loading)
    return false
  endif
  for path in keys(s_cache)
    if !get(s_cache_has_metadata, path, false)
      return false
    endif
  endfor
  for path in keys(s_loading)
    if !get(s_loading_has_metadata, path, false)
      return false
    endif
  endfor
  return true
enddef

def StringCmp(left: string, right: string): number
  if left ==# right
    return 0
  endif
  return left <# right ? -1 : 1
enddef

def EntryNumber(entry: dict<any>, key: string): number
  var value = get(entry, key, -1)
  return type(value) == v:t_number ? value : -1
enddef

def CompareDecoratedEntries(left: dict<any>, right: dict<any>, mode: string,
    reverse: bool): number
  if left.is_dir != right.is_dir
    return left.is_dir ? -1 : 1
  endif

  var cmp = 0
  if mode ==# 'extension'
    cmp = StringCmp(left.extension, right.extension)
  elseif mode ==# 'mtime' || mode ==# 'size'
    # 时间与体积默认采用更符合浏览习惯的降序。
    cmp = left.metric == right.metric ? 0 : (left.metric > right.metric ? -1 : 1)
  endif
  if cmp == 0
    cmp = StringCmp(left.folded_name, right.folded_name)
  endif
  if cmp == 0
    cmp = StringCmp(left.name, right.name)
  endif
  return reverse ? -cmp : cmp
enddef

def SortedEntries(entries: list<dict<any>>): list<dict<any>>
  var mode = SortMode()
  var reverse = !!get(g:, 'simpletree_sort_reverse', 0)
  # daemon 的基础顺序已经是目录优先、名称升序；默认路径保持零复制。
  if mode ==# 'name' && !reverse
    return entries
  endif
  # Precompute case-folded names/extensions once. A comparator can run O(n
  # log n) times, so deriving these keys inside it is costly on huge folders.
  var decorated: list<dict<any>> = []
  for entry in entries
    var name = get(entry, 'name', '')
    decorated->add({
      entry: entry,
      is_dir: !!get(entry, 'is_dir', false),
      name: name,
      folded_name: tolower(name),
      extension: mode ==# 'extension' ? tolower(fnamemodify(name, ':e')) : '',
      metric: mode ==# 'mtime' || mode ==# 'size' ? EntryNumber(entry, mode) : -1,
    })
  endfor
  decorated->sort((left, right) => CompareDecoratedEntries(left, right, mode, reverse))
  var result: list<dict<any>> = []
  for item in decorated
    result->add(item.entry)
  endfor
  return result
enddef

# =============================================================
# 工具函数
# =============================================================
# 列出当前 tab 页的候选目标窗口（排除树窗口，且仅普通缓冲区，即 buftype 为空）
def CandidateWindows(): list<dict<any>>
  var wins = getwininfo()
  var tabnr = tabpagenr()
  var res: list<dict<any>> = []
  for w in wins
    if get(w, 'tabnr', 0) != tabnr
      continue
    endif
    # 按 buffer 排除,而不是按窗口 id:同一个树 buffer 可能在这个 tab 里
    # 有窗口而 s_winid 备忘指向别处。
    if w.bufnr == s_bufnr
      continue
    endif
    # 只选择普通缓冲区窗口（buftype 为空）
    var bt = getbufvar(w.bufnr, '&buftype')
    if type(bt) == v:t_string && bt ==# ''
      var name = bufname(w.bufnr)
      res->add({winid: w.winid, winnr: w.winnr, bufnr: w.bufnr, name: name})
    endif
  endfor
  return res
enddef

# 交互式选择目标窗口；正数为窗口，0 为新建分屏，-1 为取消
def ChooseTargetWindowId(cands: list<dict<any>>): number
  if len(cands) == 0
    return 0
  endif
  var lines: list<string> = ['选择目标窗口：', '----------------------------------------']
  var i = 0
  while i < len(cands)
    var w = cands[i]
    var nm = (w.name !=# '' ? w.name : '[No Name]')
    lines->add(printf('%2d) 窗口 #%d  缓冲区 #%d  %s', i + 1, w.winnr, w.bufnr, nm))
    i += 1
  endwhile
  lines->add(printf('%2d) 新建右侧分屏', len(cands) + 1))
  var sel = inputlist(lines)
  if sel == 0
    return -1
  endif
  if sel == len(cands) + 1
    return 0
  endif
  if sel < 1 || sel > len(cands)
    return -1
  endif
  return cands[sel - 1].winid
enddef

# VS Code 式复用最近活动的编辑器组。只有第一次无法判断目标时才询问。
def ResolveTargetWindow(): number
  var cands = CandidateWindows()
  for w in cands
    if w.winid == s_target_winid
      return s_target_winid
    endif
  endfor
  if len(cands) == 0
    return 0
  endif
  if len(cands) == 1
    s_target_winid = cands[0].winid
    return s_target_winid
  endif
  var chosen = !!get(g:, 'simpletree_choose_window', 1)
    ? ChooseTargetWindowId(cands)
    : cands[0].winid
  if chosen > 0
    s_target_winid = chosen
  endif
  return chosen
enddef

# 去掉尾部斜杠；保留 Unix 根 "/"；保留 Windows 盘根 "C:/" 的形式
def RStripSlash(p: string): string
  if p ==# ''
    return ''
  endif
  var q = substitute(p, '[\\/]\+$', '', '')
  # 如果全是斜杠被去没了，说明原本就是根
  if q ==# ''
    return '/'
  endif
  # Windows 盘根保持加斜杠
  if q =~? '^[A-Za-z]:$'
    return q .. '/'
  endif
  return q
enddef

# 规范化为绝对路径，并做统一的尾斜杠处理
def CanonDir(p: string): string
  var ap = AbsPath(p)
  return RStripSlash(ap)
enddef

def AbsPath(p: string): string
  if p ==# ''
    var cwdp = simplify(fnamemodify(getcwd(), ':p'))
    Log('AbsPath resolved empty p to cwd: ' .. cwdp)
    return cwdp
  endif
  var ap = fnamemodify(p, ':p')
  if ap ==# ''
    ap = fnamemodify(getcwd() .. '/' .. p, ':p')
  endif
  ap = simplify(ap)
  return ap
enddef

def ParentDir(p: string): string
  var ap = AbsPath(p)
  var no_trail = RStripSlash(ap)
  var up = fnamemodify(no_trail, ':h')
  return CanonDir(up)
enddef

def IsDir(p: string): bool
  var res = isdirectory(p)
  return res
enddef

def PathJoin(a: string, b: string): string
  if a ==# ''
    return AbsPath(b)
  endif
  if b ==# ''
    return AbsPath(a)
  endif
  return simplify(a .. '/' .. b)
enddef

def PathExists(p: string): bool
  try
    # getftype() also sees dangling symlinks, FIFOs and sockets; these must not
    # be mistaken for a free staging/backup name.
    return getftype(p) !=# ''
  catch
    return filereadable(p) || isdirectory(p)
  endtry
enddef

# 统一分隔符为 / 并做绝对化与尾斜杠处理
def NormPath(p: string): string
  var ap = AbsPath(p)
  # Backslash is a valid Unix filename byte. Treat it as a separator only on
  # platforms where the filesystem does, otherwise completion/execution of a
  # fnameescape()'d literal backslash cannot round-trip.
  if has('win32') || has('win64') || has('win95') || has('win32unix')
    ap = substitute(ap, '\\', '/', 'g')
  endif
  return RStripSlash(ap)
enddef

def PathEq(a: string, b: string): bool
  var x = NormPath(a)
  var y = NormPath(b)
  if &fileignorecase || has('win32') || has('win64') || has('win95') || has('win32unix')
    x = tolower(x)
    y = tolower(y)
  endif
  return x ==# y
enddef

# 判断 p 是否在 root 之下（或等于 root）
def IsSubPath(root: string, p: string): bool
  if root ==# '' || p ==# ''
    return false
  endif
  var r = NormPath(root)
  var a = NormPath(p)

  # Windows 下不区分大小写
  if &fileignorecase || has('win32') || has('win64') || has('win95') || has('win32unix')
    r = tolower(r)
    a = tolower(a)
  endif

  if a ==# r
    return true
  endif

  # 对根 "/" 特判
  if r ==# '/'
    return a =~ '^/'
  endif

  # 盘根如 "C:/" 不追加第二个斜杠；普通目录检查 r + "/"
  var r_prefix = r =~? '^[A-Za-z]:/$' ? r : (r .. '/')
  return stridx(a, r_prefix) == 0
enddef

def ResolvedNormPath(path: string): string
  try
    return NormPath(resolve(AbsPath(path)))
  catch
    return NormPath(path)
  endtry
enddef

# 文件操作以解析后的工作区根为边界。对 symlink 节点本身的重命名/删除/复制
# 只检查其父目录，因为操作作用于链接对象而非链接目标。
def WorkspaceContainsOperationPath(path: string, symlink_leaf: bool = false): bool
  if s_root ==# '' || path ==# ''
    return false
  endif
  var candidate = symlink_leaf && getftype(path) ==# 'link'
    ? fnamemodify(path, ':h')
    : path
  return IsSubPath(ResolvedNormPath(s_root), ResolvedNormPath(candidate))
enddef

# Create a nested directory one component at a time. Every existing symlink is
# resolved and checked before it can be traversed, so input such as link/file
# cannot escape the workspace through an intermediate directory link.
def EnsureWorkspaceDirectory(path: string): bool
  if s_root ==# '' || path ==# ''
    return false
  endif
  var root = NormPath(s_root)
  var target = NormPath(path)
  if !IsSubPath(root, target) || !isdirectory(root)
    return false
  endif
  if PathEq(root, target)
    return WorkspaceContainsOperationPath(root)
  endif

  var relative = strpart(target, strlen(root))
  relative = substitute(relative, '^/', '', '')
  var current = root
  for component in split(relative, '/', 1)
    if component ==# '' || component ==# '.' || component ==# '..'
      return false
    endif
    current = PathJoin(current, component)
    var entry_type = getftype(current)
    if entry_type ==# ''
      try
        call mkdir(current)
      catch
        return false
      endtry
    elseif !isdirectory(current)
      return false
    endif
    if !isdirectory(current) || !WorkspaceContainsOperationPath(current)
      return false
    endif
  endfor
  return PathEq(current, target)
enddef

def TrySystemCopy(src: string, dst: string): bool
  var is_link = getftype(src) ==# 'link'
  # Vim 没有可移植的 readlink/symlink API；符号链接必须交给能保留链接的系统复制。
  if !get(g:, 'simpletree_use_system_copy', 0) && !is_link
    return false
  endif
  if is_link && !has('unix')
    return false
  endif
  if has('unix')
    # cp -a：保留属性，递归复制目录；文件同样可用
    try
      var cmd = printf('cp -a -- %s %s', shellescape(src), shellescape(dst))
      var rc = system(cmd)
      return v:shell_error == 0
    catch
      return false
    endtry
  elseif has('win32') || has('win64')
    try
      if isdirectory(src)
        # robocopy src dst /E /COPYALL /NFL /NDL（返回码为 0 或 1 认为成功）
        var cmd = printf('robocopy %s %s /E /COPYALL /NFL /NDL', shellescape(src), shellescape(dst))
        var rc = system(cmd)
        return (v:shell_error == 0 || v:shell_error == 1)
      else
        # 单文件复制：powershell Copy-Item 或内置 copy
        var cmd = printf('powershell -NoProfile -Command Copy-Item -LiteralPath %s -Destination %s -Force', shellescape(src), shellescape(dst))
        var rc = system(cmd)
        return v:shell_error == 0
      endif
    catch
      return false
    endtry
  endif
  return false
enddef

# 以固定大小的 Blob 分块复制文件，避免把大文件一次性读进 Vim 内存。
def CopyFilePortable(src: string, dst: string): bool
  try
    call mkdir(fnamemodify(dst, ':h'), 'p')
    if exists('*readblob')
      var offset = 0
      var first = true
      while true
        var chunk = readblob(src, offset, 1024 * 1024)
        if len(chunk) == 0
          if first && writefile(0z, dst, 'b') != 0
            return false
          endif
          break
        endif
        if writefile(chunk, dst, first ? 'b' : 'ab') != 0
          return false
        endif
        first = false
        offset += len(chunk)
      endwhile
    elseif writefile(readfile(src, 'b'), dst, 'b') != 0
      return false
    endif
    if exists('*getfperm') && exists('*setfperm')
      var perms = getfperm(src)
      if type(perms) == v:t_string && perms !=# ''
        call setfperm(dst, perms)
      endif
    endif
    return true
  catch
    try | call delete(dst) | catch | endtry
    return false
  endtry
enddef

# 递归复制：文件或目录
def CopyPath(src: string, dst: string): bool
  var source_type = getftype(src)
  if index(['file', 'dir', 'link'], source_type) < 0
    echohl WarningMsg
    echom '[SimpleTree] refusing to copy unsupported filesystem entry: ' .. src
    echohl None
    return false
  endif
  # 优先尝试系统复制
  if TrySystemCopy(src, dst)
    return true
  endif
  if getftype(src) ==# 'link'
    echohl WarningMsg
    echom '[SimpleTree] cannot safely copy symbolic link without a supported system copy command: ' .. src
    echohl None
    return false
  endif
  if source_type ==# 'dir'
    if !isdirectory(dst)
      try
        call mkdir(dst, 'p')
      catch
        return false
      endtry
      try
        if exists('*getfperm') && exists('*setfperm')
          var p = getfperm(src)
          if type(p) == v:t_string && p !=# ''
            call setfperm(dst, p)
          endif
        endif
      catch
      endtry
    endif
    try
      for name in readdir(src)
        if name ==# '.' || name ==# '..'
          continue
        endif
        if !CopyPath(PathJoin(src, name), PathJoin(dst, name))
          return false
        endif
      endfor
    catch
      return false
    endtry
    return true
  elseif source_type ==# 'file'
    return CopyFilePortable(src, dst)
  endif
  return false
enddef

# 递归删除
def DeletePathRecursive(p: string): bool
  if !PathExists(p)
    return true
  endif
  try
    var rc = delete(p, 'rf')
    return rc == 0
  catch
  endtry
  if isdirectory(p)
    try
      for name in readdir(p)
        if name ==# '.' || name ==# '..'
          continue
        endif
        if !DeletePathRecursive(PathJoin(p, name))
          return false
        endif
      endfor
    catch
      return false
    endtry
    try
      return delete(p, 'd') == 0
    catch
      return false
    endtry
  else
    try
      return delete(p) == 0
    catch
      return false
    endtry
  endif
enddef

# 生成与目标同目录的唯一暂存路径，使最终安装可以使用原子 rename。
def UniqueSiblingPath(dst: string, tag: string): string
  var parent = fnamemodify(dst, ':h')
  # 不嵌入原始文件名，避免接近 NAME_MAX 的合法目标无法生成暂存名。
  var seed = printf('.simpletree-%s-%x-%x', tag, getpid(), rand())
  var candidate = PathJoin(parent, seed)
  var index = 0
  while PathExists(candidate)
    index += 1
    candidate = PathJoin(parent, seed .. '-' .. index)
  endwhile
  return candidate
enddef

# 复制先写入同目录暂存项，再交换目标。任何复制失败都不会触碰旧目标。
def CopyPathSafely(src: string, dst: string): dict<any>
  var result: dict<any> = {installed: false, source_removed: false, backup: ''}
  var staged = UniqueSiblingPath(dst, 'staged')
  if !CopyPath(src, staged)
    call DeletePathRecursive(staged)
    return result
  endif

  var backup = ''
  if PathExists(dst)
    backup = UniqueSiblingPath(dst, 'backup')
    if rename(dst, backup) != 0
      call DeletePathRecursive(staged)
      return result
    endif
    result.backup = backup
  endif

  if rename(staged, dst) != 0
    call DeletePathRecursive(staged)
    if backup !=# '' && rename(backup, dst) != 0
      echohl ErrorMsg
      echom '[SimpleTree] rollback failed; original target is preserved at: ' .. backup
      echohl None
    endif
    return result
  endif
  result.installed = true

  if backup !=# '' && !DeletePathRecursive(backup)
    echohl WarningMsg
    echom '[SimpleTree] operation succeeded; old target backup remains at: ' .. backup
    echohl None
  else
    result.backup = ''
  endif
  return result
enddef

# 剪切优先使用同文件系统 rename，避免复制期间变化后再删除源的数据竞态。
# rename 不可用（通常是跨文件系统）时只安装安全副本并保留源，由用户确认后另行删除。
def MovePathSafely(src: string, dst: string): dict<any>
  var result: dict<any> = {installed: false, source_removed: false, backup: ''}
  var backup = ''
  if PathExists(dst)
    backup = UniqueSiblingPath(dst, 'backup')
    if rename(dst, backup) != 0
      return result
    endif
  endif

  if rename(src, dst) == 0
    result.installed = true
    result.source_removed = true
    if backup !=# '' && !DeletePathRecursive(backup)
      result.backup = backup
      echohl WarningMsg
      echom '[SimpleTree] move succeeded; old target backup remains at: ' .. backup
      echohl None
    endif
    return result
  endif

  if backup !=# '' && rename(backup, dst) != 0
    result.backup = backup
    echohl ErrorMsg
    echom '[SimpleTree] move rollback failed; original target is at: ' .. backup
    echohl None
    return result
  endif

  result = CopyPathSafely(src, dst)
  result.source_removed = false
  if result.installed
    echohl WarningMsg
    echom '[SimpleTree] atomic move unavailable; a complete copy was installed and the source was retained: ' .. src
    echohl None
  endif
  return result
enddef

# 同目录重命名的安全交换：先备份旧目标，失败时立即还原。
def RenamePathSafely(src: string, dst: string): bool
  # 大小写不敏感文件系统上的纯大小写改名需要经过一个中间名。
  if PathEq(src, dst) && src !=# dst
    var intermediate = UniqueSiblingPath(src, 'rename')
    if rename(src, intermediate) != 0
      return false
    endif
    if rename(intermediate, dst) == 0
      return true
    endif
    if rename(intermediate, src) != 0
      echohl ErrorMsg
      echom '[SimpleTree] case-only rename rollback failed; source is at: ' .. intermediate
      echohl None
    endif
    return false
  endif

  var backup = ''
  if PathExists(dst)
    backup = UniqueSiblingPath(dst, 'backup')
    if rename(dst, backup) != 0
      return false
    endif
  endif
  if rename(src, dst) != 0
    if backup !=# '' && rename(backup, dst) != 0
      echohl ErrorMsg
      echom '[SimpleTree] rename rollback failed; original target is at: ' .. backup
      echohl None
    endif
    return false
  endif
  if backup !=# '' && !DeletePathRecursive(backup)
    echohl WarningMsg
    echom '[SimpleTree] rename succeeded; old target backup remains at: ' .. backup
    echohl None
  endif
  return true
enddef

# 重命名/冲突改名只接受一个安全的文件名片段。
def SafeLeafName(name: string): string
  if name ==# '' || name ==# '.' || name ==# '..' || name =~# '[\\/\r\n]'
    return ''
  endif
  if has('win32') || has('win64')
    if name =~# '[<>:"|?*]' || name =~# '[ .]$'
      return ''
    endif
    if name =~? '^\%(CON\|PRN\|AUX\|NUL\|COM[1-9]\|LPT[1-9]\)\%\(\..*\)\?$'
      return ''
    endif
  endif
  return name
enddef

# 冲突处理：询问覆盖或改名或放弃
# 返回最终目标路径，或空字符串表示取消
def ResolveConflict(destDir: string, base: string): string
  var dst = PathJoin(destDir, base)
  if !IsSubPath(destDir, dst) || PathEq(destDir, dst)
    echohl ErrorMsg | echom '[SimpleTree] target must stay inside destination directory' | echohl None
    return ''
  endif
  if !PathExists(dst)
    return dst
  endif
  var prompt = 'Target exists: ' .. dst .. '. [o]verwrite / [r]ename / [c]ancel: '
  var ans = input(prompt)
  if ans ==# 'o' || ans ==# 'O'
    return dst
  elseif ans ==# 'r' || ans ==# 'R'
    var newname = input('New name: ', base)
    if SafeLeafName(newname) ==# ''
      echohl ErrorMsg | echom '[SimpleTree] enter a single safe file name' | echohl None
      return ''
    endif
    return ResolveConflict(destDir, newname)
  else
    return ''
  endif
enddef

# 新建时：循环直到唯一名字或取消
def AskUniqueName(destDir: string, base: string): string
  var name = base
  while name !=# ''
    var dst = PathJoin(destDir, name)
    if !IsSubPath(destDir, dst) || PathEq(destDir, dst)
      echohl ErrorMsg | echom '[SimpleTree] target must stay inside destination directory' | echohl None
      return ''
    endif
    if !PathExists(dst)
      return dst
    endif
    name = input('Exists: ' .. dst .. ' . Input another name (empty to cancel): ', name .. ' copy')
  endwhile
  return ''
enddef

# VS Code 的新建输入允许 foo/bar.ext；限制为目标目录内的相对路径。
def SafeRelativeName(name: string): string
  var rel = substitute(trim(name), '\\', '/', 'g')
  if rel ==# '' || rel =~# '^/' || rel =~? '^[A-Za-z]:'
    return ''
  endif
  var parts = split(rel, '/', 1)
  if len(parts) == 0
    return ''
  endif
  for part in parts
    if part ==# '' || part ==# '.' || part ==# '..'
      return ''
    endif
  endfor
  return join(parts, '/')
enddef

# 找出与一个文件或目录子树关联的普通 Vim 缓冲区。
def BuffersForPath(path: string, subtree: bool, match_resolved_identity: bool = true): list<dict<any>>
  var matches: list<dict<any>> = []
  if path ==# ''
    return matches
  endif
  var resolved_root = ResolvedNormPath(path)
  for info in getbufinfo()
    var buftype = getbufvar(info.bufnr, '&buftype')
    if (buftype !=# '' && buftype !=# 'acwrite') || get(info, 'name', '') ==# ''
      continue
    endif
    var buffer_path = NormPath(info.name)
    var resolved_buffer = ResolvedNormPath(info.name)
    var lexical_match = subtree ? IsSubPath(path, buffer_path) : PathEq(path, buffer_path)
    var identity_match = match_resolved_identity && (subtree
      ? IsSubPath(resolved_root, resolved_buffer)
      : PathEq(resolved_root, resolved_buffer))
    if lexical_match || identity_match
      matches->add({
        bufnr: info.bufnr,
        path: buffer_path,
        modified: !!get(info, 'changed', getbufvar(info.bufnr, '&modified')),
      })
    endif
  endfor
  return matches
enddef

def RefuseModifiedBuffers(path: string, subtree: bool, action: string,
    match_resolved_identity: bool = true): bool
  var modified = BuffersForPath(path, subtree, match_resolved_identity)
    ->filter((_, item) => item.modified)
  if len(modified) == 0
    return false
  endif
  var names = modified->mapnew((_, item) => fnamemodify(item.path, ':~:.'))
  if len(names) > 3
    names = names[0 : 2]
  endif
  echohl ErrorMsg
  echom printf('[SimpleTree] refusing to %s: save or discard modified buffer(s): %s%s',
    action, join(names, ', '), len(modified) > 3 ? ', ...' : '')
  echohl None
  return true
enddef

def WipeBuffersForPath(path: string, subtree: bool, match_resolved_identity: bool = true)
  for item in BuffersForPath(path, subtree, match_resolved_identity)
    # 调用者已经做过 modified 预检；仍不使用 !，防止竞态时静默丢内容。
    try
      execute 'silent bwipeout ' .. item.bufnr
    catch
      echohl WarningMsg
      echom '[SimpleTree] could not close buffer safely: ' .. item.path
      echohl None
    endtry
  endfor
enddef

def BufferRenamePlan(old_path: string, new_path: string, subtree: bool): list<dict<any>>
  var plan: list<dict<any>> = []
  var old_root = NormPath(old_path)
  var new_root = NormPath(new_path)
  # A rename migrates a lexical path namespace. Buffers reached through a
  # different symlink alias may share content identity, but their names do not
  # live below old_root and must never be rewritten by suffix arithmetic.
  for item in BuffersForPath(old_root, subtree, false)
    var destination = new_root
    if subtree && !PathEq(item.path, old_root)
      destination = new_root .. strpart(item.path, strlen(old_root))
    endif
    plan->add({bufnr: item.bufnr, old_path: item.path, new_path: destination})
  endfor
  return plan
enddef

# :file 是 Vim 唯一可靠的缓冲区改名入口。在可见窗口执行；隐藏缓冲区则借用临时窗口。
def RenameOneBuffer(bufnr: number, new_path: string): bool
  var wins = win_findbuf(bufnr)
  if len(wins) > 0
    try
      call win_execute(wins[0], 'silent keepalt file ' .. fnameescape(new_path))
      return true
    catch
      return false
    endtry
  endif

  var return_win = win_getid()
  var temp_win = 0
  try
    execute 'noautocmd botright new'
    temp_win = win_getid()
    execute 'silent noautocmd buffer ' .. bufnr
    execute 'silent keepalt file ' .. fnameescape(new_path)
    execute 'noautocmd close'
    if win_id2win(return_win) > 0
      call win_gotoid(return_win)
    endif
    return true
  catch
    var rename_error = v:exception
    if temp_win != 0 && win_id2win(temp_win) > 0
      try | call win_execute(temp_win, 'silent! noautocmd close!') | catch | endtry
    endif
    if win_id2win(return_win) > 0
      call win_gotoid(return_win)
    endif
    Log('hidden buffer rename failed: ' .. rename_error, 'WarningMsg')
    return false
  endtry
enddef

def ApplyBufferRenamePlan(plan: list<dict<any>>)
  for item in plan
    if !bufexists(item.bufnr)
      continue
    endif
    if !RenameOneBuffer(item.bufnr, item.new_path)
      echohl WarningMsg
      echom '[SimpleTree] file moved, but buffer rename failed: ' .. item.old_path
      echohl None
      # 旧名缓冲区已通过 modified 预检；安全关闭可避免后续保存时重建旧路径。
      try | execute 'silent bwipeout ' .. item.bufnr | catch | endtry
    endif
  endfor
enddef

def TrashCommand(path: string): list<string>
  if !get(g:, 'simpletree_use_trash', 1)
    return []
  endif
  if has('unix') && executable('gio')
    return ['gio', 'trash', path]
  endif
  if executable('trash-put')
    return ['trash-put', path]
  endif
  if (has('mac') || has('macunix')) && executable('trash')
    return ['trash', path]
  endif
  return []
enddef

def ShellJoin(command: list<string>): string
  return command->mapnew((_, argument) => shellescape(argument))->join(' ')
enddef

def MoveToTrash(path: string): bool
  var cmd = TrashCommand(path)
  if len(cmd) == 0
    return false
  endif
  try
    call system(ShellJoin(cmd))
    return v:shell_error == 0
  catch
    return false
  endtry
enddef

# 只刷新一个目录并在展开时重新扫描
def InvalidateAndRescan(dir_path: string)
  CancelPending(dir_path)
  if has_key(s_cache, dir_path)
    call remove(s_cache, dir_path)
  endif
  if has_key(s_cache_has_metadata, dir_path)
    call remove(s_cache_has_metadata, dir_path)
  endif
  if has_key(s_loading, dir_path)
    call remove(s_loading, dir_path)
  endif
  if has_key(s_scan_errors, dir_path)
    call remove(s_scan_errors, dir_path)
  endif
  s_filter_memo = {}
  BumpRenderEpoch()
  if GetNodeState(dir_path).expanded
    ScanDirAsync(dir_path)
  endif
  # 所有文件操作都会经过这里；git 装饰随之刷新（去抖后合并）。
  GitStatusRefresh()
enddef

def IsActionableNode(node: dict<any>): bool
  return !empty(node)
    && get(node, 'path', '') !=# ''
    && !get(node, 'loading', v:false)
    && !get(node, 'error', v:false)
enddef

# 操作目的目录：目录取自身；文件取父目录
def TargetDirForNode(node: dict<any>): string
  if !IsActionableNode(node)
    return ''
  endif
  return node.is_dir ? node.path : fnamemodify(node.path, ':h')
enddef

def BufValid(): bool
  var ok = s_bufnr > 0 && bufexists(s_bufnr)
  return ok
enddef

def TabToken(tabnr: number = 0): string
  var t = tabnr > 0 ? tabnr : tabpagenr()
  var token = gettabvar(t, 'simpletree_tab_token', '')
  if type(token) != v:t_string || token ==# ''
    s_tab_seq += 1
    token = 't' .. s_tab_seq
    settabvar(t, 'simpletree_tab_token', token)
  endif
  return token
enddef

def TabRecord(): dict<number>
  var token = TabToken()
  if !has_key(s_tabs, token)
    s_tabs[token] = {winid: 0, matchid: -1}
  endif
  return s_tabs[token]
enddef

# 丢弃已经消失的树窗口。win_id2tabwin() 是唯一跨 tabpage 有效的窗口查询,
# win_id2win() 在这里会把别的 tab 的活窗口误判成死的。
def PruneTabs()
  for [token, rec] in items(s_tabs)
    if rec.winid == 0 || win_id2tabwin(rec.winid)[0] == 0
        || winbufnr(rec.winid) != s_bufnr
      remove(s_tabs, token)
    endif
  endfor
enddef

# 仍然活着的树窗口，按 tab 记录的顺序。
def TreeWindows(): list<number>
  PruneTabs()
  return values(s_tabs)->mapnew((_, rec) => rec.winid)
enddef

# 当前 tabpage 的树窗口，没有则 0。副作用:刷新 s_winid 备忘,使得所有
# "先 WinValid() 再用 s_winid" 的调用点自动指向当前 tab 的窗口。
def TreeWin(): number
  var rec = TabRecord()
  if rec.winid == 0 || win_id2win(rec.winid) <= 0 || winbufnr(rec.winid) != s_bufnr
    # 记录缺失或过期(例如窗口被 :only 关掉后又重开):按 buffer 重新认领。
    rec.winid = 0
    if s_bufnr > 0
      var tabnr = tabpagenr()
      for info in getwininfo()
        if info.bufnr == s_bufnr && get(info, 'tabnr', 0) == tabnr
          rec.winid = info.winid
          break
        endif
      endfor
    endif
    if rec.winid == 0
      rec.matchid = -1
    endif
  endif
  s_winid = rec.winid
  return rec.winid
enddef

def WinValid(): bool
  return TreeWin() != 0
enddef

def OtherWindowId(): number
  var cands = CandidateWindows()
  return len(cands) > 0 ? cands[0].winid : 0
enddef

def Log(msg: string, hl: string = 'None')
  if get(g:, 'simpletree_debug', 0) == 0
    return
  endif
  try
    echohl hl
    echom '[SimpleTree] ' .. msg
  catch
  finally
    echohl None
  endtry
enddef

def GetNodeState(path: string): dict<any>
  if !has_key(s_state, path)
    s_state[path] = {expanded: false}
  endif
  return s_state[path]
enddef

# =============================================================
# 后端（合并）
# =============================================================
def BNextId(): number
  s_bnext_id += 1
  return s_bnext_id
enddef

# 进程生命周期交给 vendored simplecore supervisor：job_status 真实存活判定、
# 代际守卫、指数退避自动重启与崩溃循环熔断。协议解码仍留在本文件，
# DispatchLine() 作为 headless 测试的注入点必须保持按行接收。
var s_core_ready: bool = false

def SetupCore()
  if s_core_ready
    return
  endif
  s_core_ready = true
  simpletree#core#Setup({
    name: 'SimpleTree',
    exe: 'simpletree-daemon',
    path_var: 'simpletree_daemon_path',
    debug_var: 'simpletree_debug',
    codec: 'raw',
    OnLine: DispatchLine,
    OnStart: OnBackendStart,
    OnExit: OnBackendExit,
  })
enddef

def BFindBackend(): string
  SetupCore()
  return simpletree#core#FindExe()
enddef

def BIsRunning(): bool
  return simpletree#core#IsRunning()
enddef

# 新进程没有任何会话状态：重新握手，pong 到达后补挂 watch 与 git 状态。
def OnBackendStart()
  ResetBackendSessionState()
  simpletree#core#Send({type: 'ping', id: BNextId()})
enddef

def OnBackendExit(code: number, restarting: bool)
  s_bcbs = {}
  ResetBackendSessionState()
  BackendCrashed(restarting)
enddef

def HasCap(name: string): bool
  return get(s_backend_caps, name, false)
enddef

def ApplyCapabilities(caps: list<any>, protocol: number)
  s_backend_caps = {}
  for cap in caps
    if type(cap) == v:t_string
      s_backend_caps[cap] = true
    endif
  endfor
  s_backend_protocol = protocol
  # 能力确认后补挂：已展开目录的 watch 与首次 git 状态查询。
  WatchExpandedDirs()
  GitStatusRefresh()
enddef

# 协议事件统一分发。独立成函数以便 headless 测试直接注入协议行。
export def DispatchLine(line: string)
  if line ==# ''
    return
  endif
  var ev: any
  try
    ev = json_decode(line)
  catch
    return
  endtry
  if type(ev) != v:t_dict || !has_key(ev, 'type')
    return
  endif
  if ev.type ==# 'list_chunk' || ev.type ==# 'search_chunk'
    var id = ev.id
    if has_key(s_bcbs, id)
      if has_key(ev, 'entries')
        try
          s_bcbs[id].OnChunk(ev.entries)
        catch
          Log('chunk callback failed: ' .. v:exception)
        endtry
      endif
      var warnings = get(ev, 'warnings', [])
      if type(warnings) == v:t_list && len(warnings) > 0
        Log('backend warnings: ' .. join(warnings[0 : 2], '; '))
      endif
      if get(ev, 'done', v:false)
        try
          s_bcbs[id].OnDone()
        catch
          Log('done callback failed: ' .. v:exception)
        endtry
        call remove(s_bcbs, id)
      endif
    endif
  elseif ev.type ==# 'error'
    var id = get(ev, 'id', 0)
    var msg2 = get(ev, 'message', '')
    if id != 0 && has_key(s_bcbs, id)
      try
        s_bcbs[id].OnError(msg2)
      catch
        Log('error callback failed: ' .. v:exception)
      endtry
      call remove(s_bcbs, id)
    endif
  elseif ev.type ==# 'ok'
    var id = get(ev, 'id', 0)
    if id != 0 && has_key(s_bcbs, id)
      try
        s_bcbs[id].OnDone()
      catch
        Log('ok callback failed: ' .. v:exception)
      endtry
      call remove(s_bcbs, id)
    endif
  elseif ev.type ==# 'pong'
    ApplyCapabilities(get(ev, 'capabilities', []), get(ev, 'protocol_version', 1))
  elseif ev.type ==# 'fs_event'
    var dirs = get(ev, 'dirs', [])
    if type(dirs) == v:t_list
      OnFsEvent(dirs)
    endif
  elseif ev.type ==# 'git_status'
    OnGitStatusEvent(ev)
  endif
enddef

def BackendCrashed(restarting: bool = false)
  var failed_paths = keys(s_loading)
  try
    for [p, id] in items(s_pending)
      try | BCancel(id) | catch | endtry
    endfor
  catch
  endtry
  s_pending = {}
  s_loading = {}
  s_loading_has_metadata = {}
  for path in failed_paths
    if has_key(s_cache, path)
      call remove(s_cache, path)
    endif
    if has_key(s_cache_has_metadata, path)
      call remove(s_cache_has_metadata, path)
    endif
    s_scan_errors[path] = restarting
      ? 'backend restarting…'
      : 'backend exited; press R to retry'
    if isdirectory(path)
      s_dir_mtimes[path] = GetDirMtime(path)
    endif
  endfor
  if !s_open
    return
  endif
  if !restarting
    echohl ErrorMsg
    echom '[SimpleTree] backend exited. State cleared. Please retry.'
    echohl None
  endif
  Render()
enddef

def BEnsureBackend(cmd: string = ''): bool
  SetupCore()
  if cmd !=# ''
    simpletree#core#Configure('path_var', 'simpletree_daemon_path')
  endif
  return simpletree#core#Ensure()
enddef

def BStop(): void
  SetupCore()
  simpletree#core#Stop()
  s_bcbs = {}
  ResetBackendSessionState()
enddef

def BSend(req: dict<any>): bool
  return simpletree#core#Send(req)
enddef

def BList(path: string, show_hidden: bool, git_ignore: bool, max: number, with_metadata: bool, OnChunk: func, OnDone: func, OnError: func): number
  if !BEnsureBackend()
    try
      OnError('backend not available')
    catch
    endtry
    return 0
  endif
  var id = BNextId()
  s_bcbs[id] = {OnChunk: OnChunk, OnDone: OnDone, OnError: OnError}
  if !BSend({type: 'list', id: id, path: path, show_hidden: show_hidden,
      git_ignore: git_ignore, max: max, meta: with_metadata})
    call remove(s_bcbs, id)
    try
      OnError('failed to send request to backend')
    catch
    endtry
    return 0
  endif
  return id
enddef

def BCancel(id: number): void
  if id <= 0
    return
  endif
  if has_key(s_bcbs, id)
    call remove(s_bcbs, id)
  endif
  if BIsRunning()
    BSend({type: 'cancel', id: id})
  endif
enddef

# 取消所有只属于当前前端会话的异步工作。完整缓存与展开状态保留，便于下次打开复用。
def CancelFrontendWork()
  if s_render_timer != 0
    try
      call timer_stop(s_render_timer)
    catch
    endtry
    s_render_timer = 0
  endif
  if s_reveal_timer != 0
    try
      call timer_stop(s_reveal_timer)
    catch
    endtry
    s_reveal_timer = 0
  endif
  s_reveal_target = ''
  s_reveal_generation += 1
  s_reveal_waiting = {}
  if s_fs_refresh_timer != 0
    try
      call timer_stop(s_fs_refresh_timer)
    catch
    endtry
    s_fs_refresh_timer = 0
  endif
  s_fs_pending_dirs = {}
  if s_git_timer != 0
    try
      call timer_stop(s_git_timer)
    catch
    endtry
    s_git_timer = 0
  endif

  # 流式列表在 done 前写入的缓存只是半成品；取消后必须失效，避免下次打开当成完整结果。
  for p in keys(s_loading)
    if has_key(s_cache, p)
      call remove(s_cache, p)
    endif
    if has_key(s_cache_has_metadata, p)
      call remove(s_cache_has_metadata, p)
    endif
  endfor
  for [p, id] in items(s_pending)
    try
      BCancel(id)
    catch
    endtry
  endfor
  s_pending = {}
  s_loading = {}
  s_loading_has_metadata = {}
  # 也清掉尚未进入 s_pending 或已经脱离路径索引的旧请求回调。
  s_bcbs = {}
enddef

def EndFrontendSession()
  if s_open
    UnwatchAllDirs()
    s_open = false
    s_session_generation += 1
    Emit('Close', {root: s_root})
  endif
  CancelFrontendWork()
enddef

# =============================================================
# 协议 v2：watch / git status / User 事件 / 过滤
# =============================================================
def ResetBackendSessionState()
  s_backend_caps = {}
  s_backend_protocol = 0
  s_watched = {}
  s_watch_failed = {}
  s_git_status = {}
  BumpRenderEpoch()
  s_git_repo_root = ''
enddef

# doautocmd User SimpleTree{name}；无监听零开销。数据经 g:simpletree_event 传递。
def Emit(name: string, data: dict<any> = {})
  if !exists('#User#SimpleTree' .. name)
    return
  endif
  g:simpletree_event = data
  try
    execute 'doautocmd <nomodeline> User SimpleTree' .. name
  catch
    Log('event handler failed for ' .. name .. ': ' .. v:exception)
  endtry
enddef

def WatcherEnabled(): bool
  return !!get(g:, 'simpletree_use_watcher', 1) && HasCap('watch')
enddef

def WatchDir(path: string)
  if !WatcherEnabled() || path ==# ''
    return
  endif
  if has_key(s_watched, path) || has_key(s_watch_failed, path)
    return
  endif
  var id = BNextId()
  s_watched[path] = true
  var p = path
  s_bcbs[id] = {
    OnChunk: (_) => {
    },
    OnDone: () => {
    },
    OnError: (msg) => {
      # 该目录 watch 失败（如 inotify 上限），回退 mtime 轮询。
      if has_key(s_watched, p)
        call remove(s_watched, p)
      endif
      s_watch_failed[p] = true
      Log('watch failed for ' .. p .. ': ' .. msg)
    },
  }
  if !BSend({type: 'watch', id: id, path: path})
    if has_key(s_bcbs, id)
      call remove(s_bcbs, id)
    endif
    if has_key(s_watched, path)
      call remove(s_watched, path)
    endif
  endif
enddef

def UnwatchDir(path: string)
  if !has_key(s_watched, path)
    return
  endif
  call remove(s_watched, path)
  if !BIsRunning()
    return
  endif
  var id = BNextId()
  s_bcbs[id] = {
    OnChunk: (_) => {
    },
    OnDone: () => {
    },
    OnError: (_) => {
    },
  }
  if !BSend({type: 'unwatch', id: id, path: path}) && has_key(s_bcbs, id)
    call remove(s_bcbs, id)
  endif
enddef

def WatchExpandedDirs()
  if !WatcherEnabled() || s_root ==# ''
    return
  endif
  WatchDir(s_root)
  for [p, st] in items(s_state)
    if get(st, 'expanded', v:false) && isdirectory(p)
      WatchDir(p)
    endif
  endfor
enddef

def UnwatchAllDirs()
  for p in keys(s_watched)
    UnwatchDir(p)
  endfor
  s_watch_failed = {}
enddef

# fs_event 已在 daemon 侧去抖；这里再合并一拍，处理连续推送与展开状态过滤。
def OnFsEvent(dirs: list<any>)
  if !s_open
    return
  endif
  for d in dirs
    if type(d) == v:t_string && d !=# ''
      s_fs_pending_dirs[d] = true
    endif
  endfor
  if s_fs_refresh_timer != 0
    return
  endif
  var session_generation = s_session_generation
  s_fs_refresh_timer = timer_start(50, (id) => {
    if s_fs_refresh_timer == id
      s_fs_refresh_timer = 0
    endif
    if !s_open || session_generation != s_session_generation
      s_fs_pending_dirs = {}
      return
    endif
    var pending = keys(s_fs_pending_dirs)
    s_fs_pending_dirs = {}
    RefreshDirs(pending)
  })
enddef

# 定点失效并重扫一组目录，保持光标所在节点。轮询与 watch 共用此路径。
def RefreshDirs(dirs: list<string>)
  if !s_open || len(dirs) == 0
    return
  endif
  var touched = false
  for dir_path in dirs
    if !PathVisibleInTree(dir_path)
      continue
    endif
    touched = true
    if get(GetNodeState(dir_path), 'expanded', false)
      # 展开中的目录：保留旧缓存原地强制重扫。行数不抖动，光标不动，
      # 无需 RevealPath 拉回（旧实现先清缓存导致树身塌缩、光标来回闪）。
      ScanDirAsync(dir_path, true)
    else
      # 未展开的目录只失效缓存，等下次展开时再扫
      if has_key(s_cache, dir_path)
        call remove(s_cache, dir_path)
      endif
      if has_key(s_cache_has_metadata, dir_path)
        call remove(s_cache_has_metadata, dir_path)
      endif
      if has_key(s_scan_errors, dir_path)
        call remove(s_scan_errors, dir_path)
      endif
      CancelPending(dir_path)
      if has_key(s_loading, dir_path)
        call remove(s_loading, dir_path)
      endif
    endif
  endfor
  if !touched
    return
  endif
  s_filter_memo = {}
  BumpRenderEpoch()
  UpdateDirMtimes(dirs)
  GitStatusRefresh()
  ScheduleRender()
enddef

def PathVisibleInTree(path: string): bool
  if s_root ==# ''
    return false
  endif
  return PathEq(path, s_root) || IsSubPath(s_root, path)
enddef

# ---------------- git status ----------------
def GitStatusEnabled(): bool
  return !!get(g:, 'simpletree_git_status', 1) && HasCap('git-status')
enddef

def GitStatusRefresh(force: bool = false)
  if !GitStatusEnabled() || s_root ==# '' || !s_open
    return
  endif
  if s_git_timer != 0
    try | call timer_stop(s_git_timer) | catch | endtry
    s_git_timer = 0
  endif
  var session_generation = s_session_generation
  s_git_timer = timer_start(200, (id) => {
    if s_git_timer == id
      s_git_timer = 0
    endif
    if !s_open || session_generation != s_session_generation
      return
    endif
    BSend({type: 'git_status', id: BNextId(), path: s_root, force: force})
  })
enddef

def OnGitStatusEvent(ev: dict<any>)
  if !s_open
    return
  endif
  var statuses = get(ev, 'statuses', {})
  if type(statuses) != v:t_dict
    return
  endif
  s_git_status = statuses
  BumpRenderEpoch()
  s_git_repo_root = get(ev, 'repo_root', '')
  if get(ev, 'truncated', v:false)
    Log('git status truncated for ' .. s_git_repo_root, 'WarningMsg')
  endif
  Emit('GitStatusUpdated', {repo_root: s_git_repo_root, count: len(s_git_status)})
  ScheduleRender()
enddef

var s_git_symbols_cache: dict<string> = {}
var s_git_symbols_sig: string = ''

def GitSymbols(): dict<string>
  var nerd = NFEnabled()
  var sig = (nerd ? 'nf' : 'ascii') .. string(get(g:, 'simpletree_git_status_symbols', {}))
  if sig ==# s_git_symbols_sig && !empty(s_git_symbols_cache)
    return s_git_symbols_cache
  endif
  var defaults = nerd
    ? {M: '', S: '', U: '', C: '', D: ''}
    : {M: 'M', S: 'S', U: '?', C: '!', D: 'D'}
  var override = get(g:, 'simpletree_git_status_symbols', {})
  if type(override) == v:t_dict
    defaults->extend(override)
  endif
  s_git_symbols_cache = defaults
  s_git_symbols_sig = sig
  return defaults
enddef

def BookmarksFile(): string
  var configured = get(g:, 'simpletree_bookmarks_file', '')
  if type(configured) == v:t_string && configured !=# ''
    return fnamemodify(expand(configured), ':p')
  endif
  # 跟随 XDG,回落到 ~/.cache。
  var base = exists('$XDG_STATE_HOME') && $XDG_STATE_HOME !=# ''
    ? $XDG_STATE_HOME : expand('~/.local/state')
  return base .. '/simpletree/bookmarks.json'
enddef

def LoadBookmarks()
  if s_bookmarks_loaded
    return
  endif
  s_bookmarks_loaded = true
  var file = BookmarksFile()
  if !filereadable(file)
    return
  endif
  var decoded: any
  try
    decoded = json_decode(join(readfile(file), "\n"))
  catch
    Log('bookmarks file is not valid JSON: ' .. file)
    return
  endtry
  if type(decoded) != v:t_list
    return
  endif
  for entry in decoded
    if type(entry) == v:t_string && entry !=# ''
      s_bookmarks[entry] = true
    endif
  endfor
enddef

def SaveBookmarks()
  var file = BookmarksFile()
  var dir = fnamemodify(file, ':h')
  if !isdirectory(dir)
    try
      mkdir(dir, 'p')
    catch
      Log('cannot create bookmarks directory: ' .. dir)
      return
    endtry
  endif
  try
    writefile([json_encode(sort(keys(s_bookmarks)))], file)
  catch
    Log('cannot write bookmarks: ' .. v:exception)
  endtry
enddef

def IsBookmarked(path: string): bool
  return get(s_bookmarks, path, false)
enddef

export def BookmarkList(): list<string>
  LoadBookmarks()
  return sort(keys(s_bookmarks))
enddef

# 书签只对真实存在的路径有意义;删掉的文件在这里顺手清掉,免得列表越积越多。
def PruneBookmarks(): number
  LoadBookmarks()
  var gone: list<string> = []
  for path in keys(s_bookmarks)
    if !filereadable(path) && !isdirectory(path)
      add(gone, path)
    endif
  endfor
  for path in gone
    remove(s_bookmarks, path)
  endfor
  if !empty(gone)
    SaveBookmarks()
    BumpRenderEpoch()
  endif
  return len(gone)
enddef

export def OnBookmarkToggle()
  LoadBookmarks()
  var node = CursorNode()
  var path = get(node, 'path', '')
  if path ==# '' || get(node, 'loading', false) || get(node, 'error', false)
    return
  endif
  var added = false
  if has_key(s_bookmarks, path)
    remove(s_bookmarks, path)
  else
    s_bookmarks[path] = true
    added = true
  endif
  SaveBookmarks()
  # 行尾的书签标记属于行内容,缓存必须整体失效。
  BumpRenderEpoch()
  Render()
  Emit('BookmarkChanged', {path: path, bookmarked: added})
  echo printf('[SimpleTree] %s bookmark: %s',
    added ? 'added' : 'removed', fnamemodify(path, ':~'))
enddef

export def OnBookmarkJump()
  LoadBookmarks()
  PruneBookmarks()
  var marks = BookmarkList()
  if empty(marks)
    echo '[SimpleTree] no bookmarks'
    return
  endif
  var items: list<dict<any>> = []
  for path in marks
    if isdirectory(path)
      add(items, {filename: path, lnum: 1, text: 'directory'})
    else
      add(items, {filename: path, lnum: 1, text: 'file'})
    endif
  endfor
  call setqflist([], ' ', {title: 'SimpleTree bookmarks', items: items})
  copen
enddef

# 在当前树里循环跳到下一个/上一个书签。
def BookmarkStep(forward: bool)
  LoadBookmarks()
  if empty(s_bookmarks)
    echo '[SimpleTree] no bookmarks'
    return
  endif
  var lines: list<number> = []
  for i in range(len(s_line_index))
    if IsBookmarked(get(s_line_index[i], 'path', ''))
      add(lines, i + 1)
    endif
  endfor
  if empty(lines)
    echo '[SimpleTree] no bookmarks in the visible tree'
    return
  endif
  var cur = CursorLine()
  var target = forward ? lines[0] : lines[-1]
  if forward
    for l in lines
      if l > cur
        target = l
        break
      endif
    endfor
  else
    for l in reverse(copy(lines))
      if l < cur
        target = l
        break
      endif
    endfor
  endif
  if WinValid()
    win_execute(s_winid, 'call cursor(' .. target .. ', 1)')
    UpdateActiveHighlight()
  endif
enddef

export def OnBookmarkNext()
  BookmarkStep(true)
enddef

export def OnBookmarkPrev()
  BookmarkStep(false)
enddef

export def BookmarkClear()
  LoadBookmarks()
  var n = len(s_bookmarks)
  s_bookmarks = {}
  SaveBookmarks()
  BumpRenderEpoch()
  Render()
  echo printf('[SimpleTree] cleared %d bookmark%s', n, n == 1 ? '' : 's')
enddef

# ─────────────────── 标记（批量操作）───────────────────
#
# 书签是持久的"我关心这个路径"；标记是一次性的"下一个操作作用于这些路径"。
# 剪贴板本来就是 {mode, items: [...]}，OnPaste() 也早就在 items 上循环，只是
# 一直只放一个元素——标记只是把那条已有的路径喂满。
#
# 标记会改变行内容（行尾多一个符号），所以每次增删都必须 BumpRenderEpoch()，
# 规则与书签相同；tests/vim_render_cache.vim 会在忘记时失败。
var s_marked: dict<bool> = {}

def MarkSymbol(): string
  var sym = get(g:, 'simpletree_mark_symbol', '✓')
  return type(sym) == v:t_string && sym !=# '' ? sym : '✓'
enddef

def IsMarked(path: string): bool
  return get(s_marked, path, false)
enddef

# 已标记的路径，按路径排序——批量操作的顺序必须与树的显示顺序无关，否则
# 同一批标记在不同展开状态下会得到不同的结果。
def MarkedPaths(): list<string>
  return sort(keys(s_marked))
enddef

# 丢掉指向已消失路径的标记。整表清空会让 H / I（它们走 Refresh()）把辛苦
# 建起来的标记集合一起抹掉，那是比幽灵路径更烦人的行为。
def PruneMarks()
  var dropped = 0
  for path in keys(s_marked)
    if !PathExists(path)
      remove(s_marked, path)
      dropped += 1
    endif
  endfor
  if dropped > 0
    BumpRenderEpoch()
  endif
enddef

def ClearMarks(render: bool = false)
  if empty(s_marked)
    return
  endif
  s_marked = {}
  BumpRenderEpoch()
  if render
    Render()
  endif
enddef

# 批量操作的目标集合：有标记时用标记，否则用光标所在节点。
# 返回空表示没有可操作的目标，调用方负责给出提示。
def ActionTargets(): list<string>
  if !empty(s_marked)
    return MarkedPaths()
  endif
  var node = CursorNode()
  return IsActionableNode(node) ? [node.path] : []
enddef

# 最多列出 max 个名字，其余折叠成 "(and N more)"。破坏性操作的确认框必须
# 让人一眼看清作用范围，但不能长到把屏幕顶掉。
def SummarizePaths(paths: list<string>, maximum: number = 5): string
  var names = paths->copy()->map((_, p) => fnamemodify(RStripSlash(p), ':t'))
  if len(names) <= maximum
    return join(names, ', ')
  endif
  return join(names[0 : maximum - 1], ', ')
    .. printf(' (and %d more)', len(names) - maximum)
enddef

def MarkPath(path: string): bool
  if path ==# '' || PathEq(path, s_root)
    return false
  endif
  s_marked[path] = true
  return true
enddef

export def OnMarkToggle()
  var node = CursorNode()
  if !IsActionableNode(node)
    echo '[SimpleTree] nothing to mark'
    return
  endif
  if get(node, 'is_root', v:false) || PathEq(node.path, s_root)
    echo '[SimpleTree] the workspace root cannot be marked'
    return
  endif
  if has_key(s_marked, node.path)
    remove(s_marked, node.path)
  else
    s_marked[node.path] = true
  endif
  BumpRenderEpoch()
  Render()
  # 与书签一致：标记后往下走一行，连续标记不用手动移动光标。
  var lnum = CursorLine()
  if lnum > 0 && lnum < len(s_line_index) && WinValid()
    try | call win_execute(s_winid, 'normal! ' .. (lnum + 1) .. 'G') | catch | endtry
  endif
  echo printf('[SimpleTree] %d marked', len(s_marked))
enddef

# 可视模式下对选区内的每一行做标记。整段全部已标记时取消标记，否则补齐——
# 这样重复按同一个键在同一段选区上是可逆的。
export def OnMarkRange()
  if !WinValid()
    return
  endif
  var first = line("'<")
  var last = line("'>")
  if first <= 0 || last <= 0
    return
  endif
  var paths: list<string> = []
  for lnum in range(max([1, first]), min([last, len(s_line_index)]))
    var node = s_line_index[lnum - 1]
    if !IsActionableNode(node) || PathEq(get(node, 'path', ''), s_root)
      continue
    endif
    paths->add(node.path)
  endfor
  if empty(paths)
    echo '[SimpleTree] nothing to mark'
    return
  endif
  var all_marked = paths->copy()->filter((_, p) => !IsMarked(p))->empty()
  for p in paths
    if all_marked
      if has_key(s_marked, p)
        remove(s_marked, p)
      endif
    else
      MarkPath(p)
    endif
  endfor
  BumpRenderEpoch()
  Render()
  echo printf('[SimpleTree] %d marked', len(s_marked))
enddef

# 标记光标节点的全部可见同级节点（同一父目录、同一缩进层）。
export def OnMarkSiblings()
  if !WinValid()
    return
  endif
  var node = CursorNode()
  if !IsActionableNode(node)
    echo '[SimpleTree] nothing to mark'
    return
  endif
  var parent = fnamemodify(RStripSlash(node.path), ':h')
  var depth = get(node, 'depth', -1)
  var added = 0
  for entry in s_line_index
    if !IsActionableNode(entry) || get(entry, 'depth', -2) != depth
      continue
    endif
    if fnamemodify(RStripSlash(entry.path), ':h') !=# parent
      continue
    endif
    if !IsMarked(entry.path) && MarkPath(entry.path)
      added += 1
    endif
  endfor
  if added == 0
    echo '[SimpleTree] no new siblings to mark'
    return
  endif
  BumpRenderEpoch()
  Render()
  echo printf('[SimpleTree] %d marked', len(s_marked))
enddef

export def OnMarkClear()
  if empty(s_marked)
    echo '[SimpleTree] no marks'
    return
  endif
  var n = len(s_marked)
  ClearMarks(true)
  echo printf('[SimpleTree] cleared %d mark%s', n, n == 1 ? '' : 's')
enddef

def GitCodeFor(path: string): string
  if empty(s_git_status)
    return ''
  endif
  return get(s_git_status, path, '')
enddef

# ---------------- 树内过滤 ----------------
def FilterActive(): bool
  return s_filter_query !=# ''
enddef

def NameMatchesFilter(name: string): bool
  return stridx(tolower(name), tolower(s_filter_query)) >= 0
enddef

# 只检查已加载缓存中的后代；未加载的目录在过滤态默认隐藏。
def DirHasFilterMatch(path: string): bool
  if has_key(s_filter_memo, path)
    return s_filter_memo[path]
  endif
  var found = false
  if has_key(s_cache, path)
    for e in s_cache[path]
      if NameMatchesFilter(e.name)
        found = true
        break
      endif
      if e.is_dir && DirHasFilterMatch(e.path)
        found = true
        break
      endif
    endfor
  endif
  s_filter_memo[path] = found
  return found
enddef

def FilterAllowsEntry(e: dict<any>): bool
  if !FilterActive()
    return true
  endif
  if NameMatchesFilter(e.name)
    return true
  endif
  return e.is_dir && DirHasFilterMatch(e.path)
enddef

export def OnFilter()
  var q = ''
  try
    q = input('Filter (empty to clear): ', s_filter_query)
  catch
    return
  endtry
  s_filter_query = q
  s_filter_memo = {}
  BumpRenderEpoch()
  Emit('FilterChanged', {query: q})
  Render()
  if q ==# ''
    echo '[SimpleTree] filter cleared'
  endif
enddef

# ---------------- 跳转式查找 ----------------
export def OnFind()
  var q = ''
  try
    q = input('Find: ', s_find_query)
  catch
    return
  endtry
  if q ==# ''
    return
  endif
  s_find_query = q
  FindJump(1)
enddef

export def OnFindNext()
  if s_find_query ==# ''
    echo '[SimpleTree] no previous find; press / first'
    return
  endif
  FindJump(1)
enddef

export def OnFindPrev()
  if s_find_query ==# ''
    echo '[SimpleTree] no previous find; press / first'
    return
  endif
  FindJump(-1)
enddef

def FindJump(direction: number)
  if !WinValid() || len(s_line_index) == 0
    return
  endif
  var total = len(s_line_index)
  var pos = getcurpos(s_winid)
  var start = len(pos) > 1 ? pos[1] : 1
  var needle = tolower(s_find_query)
  var i = 1
  while i <= total
    var lnum = ((start - 1 + direction * i) % total + total) % total + 1
    var name = get(s_line_index[lnum - 1], 'name', '')
    if name !=# '' && stridx(tolower(name), needle) >= 0
      try | call win_execute(s_winid, 'normal! ' .. lnum .. 'G') | catch | endtry
      return
    endif
    i += 1
  endwhile
  echo '[SimpleTree] no match: ' .. s_find_query
enddef

# =============================================================
# 前端 <-> 后端
# =============================================================
def CancelPending(path: string)
  if has_key(s_pending, path)
    try
      var pid = s_pending[path]
      BCancel(pid)
    catch
    endtry
    call remove(s_pending, path)
  endif
  if has_key(s_loading_has_metadata, path)
    call remove(s_loading_has_metadata, path)
  endif
enddef

def ScheduleRender()
  if !s_open
    return
  endif
  if !exists('*timer_start')
    Render()
    return
  endif
  if s_render_timer != 0
    return
  endif
  try
    var session_generation = s_session_generation
    s_render_timer = timer_start(20, (id) => {
      if s_render_timer == id
        s_render_timer = 0
      endif
      if !s_open || session_generation != s_session_generation
        return
      endif
      Render()
    })
  catch
    Render()
  endtry
enddef

# force = true：跳过缓存/错误守卫强制重扫。旧缓存保留到本次扫描完成后原子
# 替换，避免中间 Render 出现子项消失、树身抖动、光标被顶走的闪烁。
def ScanDirAsync(path: string, force: bool = false)
  if !s_open
    return
  endif
  if force
    if has_key(s_loading, path)
      call remove(s_loading, path)
    endif
    if has_key(s_scan_errors, path)
      call remove(s_scan_errors, path)
    endif
  elseif has_key(s_cache, path) || has_key(s_scan_errors, path) || get(s_loading, path, v:false)
    return
  endif

  CancelPending(path)

  s_loading[path] = true
  var keep_stale = has_key(s_cache, path)
  var acc: list<dict<any>> = []
  var p = path
  var req_id: number = 0
  var session_generation = s_session_generation
  var request_has_metadata = SortNeedsMetadata()
  s_loading_has_metadata[path] = request_has_metadata

  req_id = BList(
    p,
    !s_hide_dotfiles,
    s_git_ignore,
    g:simpletree_page,
    request_has_metadata,
    (entries) => {
      if !s_open || session_generation != s_session_generation
        return
      endif
      acc += entries
      if has_key(s_scan_errors, p)
        call remove(s_scan_errors, p)
      endif
      # 刷新已有目录时不发布中间结果，保留旧内容直到 OnDone 一次性替换
      # Only the daemon's native name/ascending order can stream directly.
      # Publishing every chunk in another mode would re-sort the entire growing
      # directory after each batch (near O(chunks * n log n)); publish those
      # modes atomically from OnDone instead.
      if !keep_stale && SortMode() ==# 'name' && !get(g:, 'simpletree_sort_reverse', 0)
        s_cache[p] = acc
        s_cache_has_metadata[p] = request_has_metadata
        ScheduleRender()
      endif
    },
    () => {
      if !s_open || session_generation != s_session_generation
        return
      endif
      if has_key(s_loading, p)
        call remove(s_loading, p)
      endif
      if has_key(s_loading_has_metadata, p)
        call remove(s_loading_has_metadata, p)
      endif
      s_cache[p] = acc
      s_cache_has_metadata[p] = request_has_metadata
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
      endif
      # 更新目录修改时间缓存
      if isdirectory(p)
        s_dir_mtimes[p] = GetDirMtime(p)
      endif
      # 列表成功后订阅该目录的文件系统事件（能力可用时）。
      WatchDir(p)
      s_filter_memo = {}
      BumpRenderEpoch()
      # A reveal may attach its current token to a scan that was already in
      # flight. Only that registered token may complete it; unrelated/stale
      # scans still populate cache but cannot move selection.
      var reveal_generation = get(s_reveal_waiting, p, 0)
      if has_key(s_reveal_waiting, p)
        remove(s_reveal_waiting, p)
      endif
      if reveal_generation > 0 && reveal_generation == s_reveal_generation
          && s_reveal_target !=# ''
        # Render synchronously for this explicit user action so a slow
        # pre-existing scan cannot outlive the bounded fallback timer and lose
        # the reveal. This branch replaces (rather than duplicates) the normal
        # scheduled render, keeping render statistics honest.
        Render()
        if FocusIfPresent(s_reveal_target)
          s_reveal_target = ''
          s_reveal_waiting = {}
          if s_reveal_timer != 0
            try | call timer_stop(s_reveal_timer) | catch | endtry
            s_reveal_timer = 0
          endif
        endif
      else
        ScheduleRender()
      endif
    },
    (msg) => {
      if !s_open || session_generation != s_session_generation
        return
      endif
      if has_key(s_loading, p)
        call remove(s_loading, p)
      endif
      if has_key(s_loading_has_metadata, p)
        call remove(s_loading_has_metadata, p)
      endif
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
      endif
      if has_key(s_reveal_waiting, p)
        remove(s_reveal_waiting, p)
      endif
      if has_key(s_cache, p)
        call remove(s_cache, p)
      endif
      if has_key(s_cache_has_metadata, p)
        call remove(s_cache_has_metadata, p)
      endif
      s_scan_errors[p] = type(msg) == v:t_string && msg !=# '' ? msg : 'unknown scan error'
      if isdirectory(p)
        s_dir_mtimes[p] = GetDirMtime(p)
      endif
      if type(msg) == v:t_string && msg !=# ''
        echohl WarningMsg
        echom '[SimpleTree] backend error: ' .. msg
        echohl None
      endif
      ScheduleRender()
    }
  )

  if req_id > 0
    s_pending[path] = req_id
  else
    if has_key(s_loading, path)
      call remove(s_loading, path)
    endif
    if has_key(s_loading_has_metadata, path)
      call remove(s_loading_has_metadata, path)
    endif
    if has_key(s_reveal_waiting, path)
      remove(s_reveal_waiting, path)
    endif
  endif
enddef

# =============================================================
# 语法高亮（SimpleTree / SimpleTree Help）
# =============================================================
var s_syntax_sig: string = ''
def ComputeSyntaxSig(): string
  # 如果 icon 版本未变，直接返回缓存签名
  if s_cached_syntax_sig_ver == s_icon_version && s_cached_syntax_sig !=# ''
    return s_cached_syntax_sig
  endif
  # 将影响语法的关键配置进行签名
  SetupFileIconMap()
  var parts: list<string> = []
  parts->add('NF=' .. (NFEnabled() ? '1' : '0'))
  parts->add('show_icons=' .. (get(g:, 'simpletree_show_file_icons', 1) ? '1' : '0'))
  for [k, v] in items(s_icons)
    parts->add(k .. '=' .. v)
  endfor
  for [k, v] in items(s_file_icon_map)
    parts->add('file:' .. k .. '=' .. v)
  endfor
  s_cached_syntax_sig = join(parts, '|')
  s_cached_syntax_sig_ver = s_icon_version
  return s_cached_syntax_sig
enddef

def EnsureSyntaxTree(): void
  if !WinValid()
    return
  endif
  var sig = ComputeSyntaxSig()
  if s_syntax_sig !=# sig
    s_syntax_sig = sig
    SetupSyntaxTree()
  endif
enddef

def SetupSyntaxTree(): void
  if !WinValid()
    return
  endif
  try
    var cmds: list<string> = []

    # 文件树缓冲区只包含本插件语法，整体清理可避免不存在的组触发 E28。
    cmds->add('syntax clear')

    # 基础匹配
    cmds->add('syntax match SimpleTreeHidden "^\s*.\{-}\s\zs\.\S\+"')
    cmds->add('syntax match SimpleTreeLoading "Loading\.\.\."')
    var modified_pat = escape(get(g:, 'simpletree_modified_symbol', '●'), '\')
    cmds->add('syntax match SimpleTreeModified "\V' .. modified_pat .. '\m$"')
    # 标记符号总是装饰串的最后一段，所以锚在行尾即可。
    cmds->add('syntax match SimpleTreeMark "\V' .. escape(MarkSymbol(), '\') .. '\m$"')

    # 目录：图标 -> 名称 -> 斜杠（nextgroup + contained）
    var dir1 = s_icons.dir
    var dir2 = s_icons.dir_open
    var dir_pat = '\%(' .. '\V' .. escape(dir1, '\') .. '\m' .. '\|' .. '\V' .. escape(dir2, '\') .. '\m' .. '\)'
    cmds->add('syntax match SimpleTreeIconDir "^\s*\zs' .. dir_pat .. '\ze\s" nextgroup=SimpleTreeDirName,SimpleTreeDirSlash skipwhite')
    cmds->add('syntax match SimpleTreeDirName "[^/]\+" contained nextgroup=SimpleTreeDirSlash')
    cmds->add('syntax match SimpleTreeDirSlash "/$" contained')

    # 文件 icon 分色（仅当启用 Nerd Font 且显示文件图标）
    if NFEnabled() && !!get(g:, 'simpletree_show_file_icons', 1)
      SetupFileIconMap()
      # 用 dict 做 O(1) 分类查找，替代 index() 的 O(n) 扫描
      var cat_map: dict<string> = {}
      for ext in ['vim', 'lua', 'py', 'rb', 'go', 'rs', 'js', 'ts', 'jsx', 'tsx', 'c', 'h', 'cpp', 'hpp', 'java', 'kt']
        cat_map[ext] = 'SimpleTreeIconLang'
      endfor
      for ext in ['sh', 'bash', 'zsh']
        cat_map[ext] = 'SimpleTreeIconScript'
      endfor
      for ext in ['html', 'css', 'scss']
        cat_map[ext] = 'SimpleTreeIconWeb'
      endfor
      for ext in ['json', 'toml', 'yml', 'yaml', 'ini', 'lock']
        cat_map[ext] = 'SimpleTreeIconData'
      endfor
      for ext in ['md', 'txt', 'pdf']
        cat_map[ext] = 'SimpleTreeIconDoc'
      endfor
      for ext in ['png', 'jpg', 'jpeg', 'gif', 'svg', 'webp']
        cat_map[ext] = 'SimpleTreeIconImage'
      endfor
      for ext in ['zip', 'tar', 'gz', '7z']
        cat_map[ext] = 'SimpleTreeIconArchive'
      endfor

      for [ext, ico] in items(s_file_icon_map)
        var grp = get(cat_map, ext, 'SimpleTreeIconFileDefault')
        var pat = '^\s*\zs\V' .. escape(ico, '\') .. '\m\ze\s'
        cmds->add('syntax match ' .. grp .. ' "' .. pat .. '"')
      endfor
    else
      cmds->add('syntax match SimpleTreeIconFileDefault "^\s*\zs\S\+\ze\s"')
    endif

    # 隐藏文件/目录的图标置灰（优先生效，放在分色匹配之后）
    cmds->add('syntax match SimpleTreeIconHidden "^\s*\zs\S\+\ze\s\."')
    cmds->add('highlight default SimpleTreeIconHidden ctermfg=245 guifg=#6a6a6a')

    # 自定义目录颜色组
    var dir_cterm = get(g:, 'simpletree_dir_ctermfg', 75)
    var dir_gui   = get(g:, 'simpletree_dir_guifg', '#61afef')
    cmds->add('highlight default SimpleTreeDirColor ctermfg=' .. dir_cterm .. ' guifg=' .. dir_gui)
    cmds->add('highlight default link SimpleTreeDirName SimpleTreeDirColor')
    cmds->add('highlight default link SimpleTreeIconDir SimpleTreeDirColor')
    cmds->add('highlight default link SimpleTreeDirSlash SimpleTreeDirColor')

    # 其他高亮链接
    cmds->add('highlight default link SimpleTreeHidden Comment')
    cmds->add('highlight default link SimpleTreeLoading WarningMsg')
    cmds->add('highlight default link SimpleTreeModified WarningMsg')
    cmds->add('highlight default link SimpleTreeMark Statement')
    cmds->add('highlight default link SimpleTreeActiveFile CursorLine')
    cmds->add('highlight default link SimpleTreeIconLang Type')
    cmds->add('highlight default link SimpleTreeIconScript Statement')
    cmds->add('highlight default link SimpleTreeIconWeb PreProc')
    cmds->add('highlight default link SimpleTreeIconData Constant')
    cmds->add('highlight default link SimpleTreeIconDoc Identifier')
    cmds->add('highlight default link SimpleTreeIconImage Special')
    cmds->add('highlight default link SimpleTreeIconArchive WarningMsg')
    cmds->add('highlight default link SimpleTreeIconFileDefault Special')
    cmds->add('highlight default link SimpleTreeGitModified WarningMsg')
    cmds->add('highlight default link SimpleTreeGitStaged DiffAdd')
    cmds->add('highlight default link SimpleTreeGitUntracked Comment')
    cmds->add('highlight default link SimpleTreeGitConflict ErrorMsg')
    cmds->add('highlight default link SimpleTreeGitDeleted DiffDelete')

    # :syntax clear 会吞掉命令分隔符后的内容，逐条执行才能可靠建立高亮组。
    for cmd in cmds
      call win_execute(s_winid, cmd)
    endfor
  catch
  endtry
enddef

def SetupSyntaxHelp(): void
  if s_help_winid == 0 || win_id2win(s_help_winid) <= 0
    return
  endif
  # 仅对分屏帮助缓冲区设置（浮窗不做细粒度语法，以免依赖 popup_getbuf）
  try
    call win_execute(s_help_winid, 'silent! syntax clear SimpleTreeHelpTitle SimpleTreeHelpSep SimpleTreeHelpKey')
    call win_execute(s_help_winid, 'syntax match SimpleTreeHelpTitle ''^SimpleTree.*$''')
    call win_execute(s_help_winid, 'syntax match SimpleTreeHelpSep ''^-\{2,}$''')
    # 匹配行首的快捷键（以至少两个空格与说明分隔）
    call win_execute(s_help_winid, 'syntax match SimpleTreeHelpKey ''^\zs\S\+\ze\s\{2,}''')

    call win_execute(s_help_winid, 'highlight default link SimpleTreeHelpTitle Title')
    call win_execute(s_help_winid, 'highlight default link SimpleTreeHelpSep Comment')
    call win_execute(s_help_winid, 'highlight default link SimpleTreeHelpKey Identifier')
  catch
  endtry
enddef

# =============================================================
# 渲染
# =============================================================
# action 名 -> autoload 函数名。g:simpletree_mappings 以 {键: action} 覆盖默认表，
# 值为空字符串表示禁用该键。
const KEY_ACTIONS: dict<string> = {
  open: 'OnEnter',
  expand: 'OnExpand',
  collapse: 'OnCollapse',
  collapse_all: 'OnCollapseAll',
  refresh: 'OnRefresh',
  toggle_hidden: 'OnToggleHidden',
  toggle_git_ignore: 'OnToggleGitIgnore',
  close: 'OnClose',
  root_here: 'OnRootHere',
  root_up: 'OnRootUp',
  root_prompt: 'OnRootPrompt',
  root_cwd: 'OnRootCwd',
  root_current: 'OnRootCurrent',
  toggle_root_lock: 'OnToggleRootLock',
  copy: 'OnCopy',
  cut: 'OnCut',
  paste: 'OnPaste',
  new_file: 'OnNewFile',
  new_folder: 'OnNewFolder',
  rename: 'OnRename',
  delete: 'OnDelete',
  help: 'ShowHelp',
  open_vsplit: 'OnOpenVSplit',
  open_split: 'OnOpenSplit',
  open_tab: 'OnOpenTab',
  preview: 'OnPreview',
  reveal_active: 'OnRevealActive',
  yank_name: 'OnYankPath',
  yank_path: 'OnYankAbsPath',
  system_open: 'OnSystemOpen',
  filter: 'OnFilter',
  find: 'OnFind',
  find_next: 'OnFindNext',
  find_prev: 'OnFindPrev',
  bookmark_toggle: 'OnBookmarkToggle',
  bookmark_list: 'OnBookmarkJump',
  bookmark_next: 'OnBookmarkNext',
  bookmark_prev: 'OnBookmarkPrev',
  sort_cycle: 'OnSortCycle',
  sort_reverse: 'ToggleSortReverse',
  mark_toggle: 'OnMarkToggle',
  mark_siblings: 'OnMarkSiblings',
  mark_clear: 'OnMarkClear',
}

# action -> 可视模式下的函数名。装在与普通模式同一个键上，所以重绑
# mark_toggle 会把可视映射一起带走，不会留下一个指向旧键的孤儿。
const VISUAL_ACTIONS: dict<string> = {
  mark_toggle: 'OnMarkRange',
}

const DEFAULT_KEYS: dict<string> = {
  '<CR>': 'open',
  'o': 'open',
  '<2-LeftMouse>': 'open',
  'l': 'expand',
  '<Right>': 'expand',
  'h': 'collapse',
  '<Left>': 'collapse',
  '<BS>': 'collapse',
  'R': 'refresh',
  'H': 'toggle_hidden',
  'I': 'toggle_git_ignore',
  'q': 'close',
  'e': 'root_here',
  'U': 'root_up',
  'C': 'root_prompt',
  '.': 'root_cwd',
  'd': 'root_current',
  'L': 'toggle_root_lock',
  'c': 'copy',
  'x': 'cut',
  'p': 'paste',
  'a': 'new_file',
  'n': 'new_file',
  'A': 'new_folder',
  'N': 'new_folder',
  'r': 'rename',
  'D': 'delete',
  'z': 'collapse_all',
  '?': 'help',
  'V': 'open_vsplit',
  'S': 'open_split',
  't': 'open_tab',
  '<C-v>': 'open_vsplit',
  '<C-x>': 'open_split',
  '<C-t>': 'open_tab',
  'P': 'preview',
  'f': 'reveal_active',
  'y': 'yank_name',
  'Y': 'yank_path',
  'gx': 'system_open',
  'F': 'filter',
  '/': 'find',
  ']f': 'find_next',
  '[f': 'find_prev',
  'm': 'bookmark_toggle',
  "'": 'bookmark_list',
  ']b': 'bookmark_next',
  '[b': 'bookmark_prev',
  's': 'sort_cycle',
  'gs': 'sort_reverse',
  '<Space>': 'mark_toggle',
  'gm': 'mark_siblings',
  'gM': 'mark_clear',
}

# 合并默认表、g:simpletree_collapse_all_key 兼容别名与 g:simpletree_mappings。
export def EffectiveKeymap(): dict<string>
  var mapped = copy(DEFAULT_KEYS)
  var ca_key = get(g:, 'simpletree_collapse_all_key', 'z')
  if type(ca_key) == v:t_string && ca_key !=# '' && ca_key !=# 'z'
    if get(mapped, 'z', '') ==# 'collapse_all'
      call remove(mapped, 'z')
    endif
    mapped[ca_key] = 'collapse_all'
  endif
  var override = get(g:, 'simpletree_mappings', {})
  if type(override) == v:t_dict
    for [key, action] in items(override)
      if type(action) != v:t_string
        continue
      endif
      if action ==# ''
        if has_key(mapped, key)
          call remove(mapped, key)
        endif
      elseif has_key(KEY_ACTIONS, action)
        mapped[key] = action
      else
        Log('unknown mapping action: ' .. action, 'WarningMsg')
      endif
    endfor
  endif
  return mapped
enddef

def InstallKeymaps()
  var cmds: list<string> = []
  for [key, action] in items(EffectiveKeymap())
    var Fn = get(KEY_ACTIONS, action, '')
    if Fn ==# ''
      continue
    endif
    cmds->add('nnoremap <nowait> <silent> <buffer> ' .. key .. ' <Cmd>call simpletree#' .. Fn .. '()<CR>')
    var VFn = get(VISUAL_ACTIONS, action, '')
    if VFn !=# ''
      # `:<C-u>` 而不是 `<Cmd>`：'< 和 '> 只有在离开可视模式后才更新，
      # <Cmd> 保持可视模式，读到的会是上一次选区。
      cmds->add('xnoremap <nowait> <silent> <buffer> ' .. key
        .. ' :<C-u>call simpletree#' .. VFn .. '()<CR>')
    endif
  endfor
  call win_execute(s_winid, join(cmds, " | "))
enddef

def RegisterGitPropTypes()
  for type_name in ['SimpleTreeGitModified', 'SimpleTreeGitStaged', 'SimpleTreeGitUntracked', 'SimpleTreeGitConflict', 'SimpleTreeGitDeleted']
    try
      call prop_type_add(type_name, {bufnr: s_bufnr, highlight: type_name, combine: true})
    catch
      # 已注册（重复打开同一 buffer）时忽略。
    endtry
  endfor
enddef

def EnsureWindowAndBuffer()
  if !s_open
    return
  endif
  if WinValid()
    try
      call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)
    catch
    endtry
    return
  endif

  noautocmd execute 'topleft vertical vsplit'
  s_winid = win_getid()

  # 已经有树 buffer 时（在别的 tab 里开着）复用它:一个 buffer 多个窗口,
  # 渲染只写一次两个 tab 就都更新了。以前这里无条件 enew + `file SimpleTree`,
  # 第二个 tab 会撞上 E95 "Buffer with this name already exists" 并留下一个
  # 没有 filetype 的空窗口。
  if BufValid()
    noautocmd execute 'silent buffer ' .. s_bufnr
  else
    noautocmd call win_execute(s_winid, 'silent enew')
    s_bufnr = winbufnr(s_winid)
    call win_execute(s_winid, 'file SimpleTree')
  endif
  var rec = TabRecord()
  rec.winid = s_winid

  call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)

  var opts = [
    'setlocal buftype=nofile',
    'setlocal bufhidden=wipe',
    'setlocal nobuflisted',
    'setlocal noswapfile',
    'setlocal nowrap',
    'setlocal nonumber',
    'setlocal norelativenumber',
    'setlocal foldcolumn=0',
    'setlocal signcolumn=no',
    'setlocal cursorline',
    'setlocal winfixwidth',
    'setlocal filetype=simpletree'
  ]
  for cmd in opts
    call win_execute(s_winid, cmd)
  endfor
  call SetupSyntaxTree()

  InstallKeymaps()
  RegisterGitPropTypes()

  call win_execute(s_winid, 'augroup SimpleTreeBuf | autocmd! | autocmd BufWipeout <buffer> ++once call simpletree#OnBufWipe() | autocmd WinClosed <buffer> call simpletree#OnAutoClose() | augroup END')

  # 状态栏显示当前根路径
  call win_execute(s_winid, 'setlocal statusline=%{simpletree#StatusLine()}')
enddef

# ─────────────────── 子树渲染缓存 ───────────────────
#
# Render() 过去每次展开/折叠都要把整棵可见树重建一遍：对每个可见节点做字符串
# 拼接与字典构造，11k 行时约 60ms,而这发生在每一次按键上。现在按目录缓存已
# 渲染好的切片,只重建真正变化的那部分,其余用 extend() 拼接。
#
# 正确性只依赖一条规则:BuildLines 读到的每一样状态,要么进入下面的
# SubtreeValid() 校验,要么调用 BumpRenderEpoch()。
# tests/vim_render_cache.vim 通过对比 "走缓存" 与 "禁用缓存" 两种渲染结果来
# 钉死这条规则。
#
# path -> {depth, epoch, entries, count, dirs, lines, idx}
var s_subtree_cache: dict<dict<any>> = {}
var s_render_epoch: number = 0
var s_render_cfg_sig: string = ''
# 测试用:置 true 后完全绕过缓存,用于产出参照渲染。
var s_render_cache_off: bool = false

# 轻量常驻统计只记录已经发生的渲染工作；读取与重置绝不能触碰 epoch 或缓存，
# 因而 :SimpleTreeStats 本身不会改变下一次渲染的 hit/miss。
var s_render_stats: dict<any> = {
  renders: 0,
  cache_hits: 0,
  cache_misses: 0,
  invalidations: 0,
  invalidated_subtrees: 0,
  total_ms: 0.0,
  last_ms: 0.0,
  max_ms: 0.0,
  visible_lines: 0,
  last_changed_lines: 0,
  total_changed_lines: 0,
  buffer_writes: 0,
}

def ResetRenderStats()
  s_render_stats = {
    renders: 0,
    cache_hits: 0,
    cache_misses: 0,
    invalidations: 0,
    invalidated_subtrees: 0,
    total_ms: 0.0,
    last_ms: 0.0,
    max_ms: 0.0,
    visible_lines: 0,
    last_changed_lines: 0,
    total_changed_lines: 0,
    buffer_writes: 0,
  }
enddef

def RenderStatsSnapshot(): dict<any>
  var snapshot = deepcopy(s_render_stats)
  # Before Vim 9.0.1108 arithmetic on values read directly from dict<any>
  # could fail with E1012. Keep the mixed Number/Float storage, but narrow
  # every operand before doing timing or cache-rate arithmetic.
  var renders: number = get(snapshot, 'renders', 0)
  var total_ms: float = get(snapshot, 'total_ms', 0.0)
  var cache_hits: number = get(snapshot, 'cache_hits', 0)
  var cache_misses: number = get(snapshot, 'cache_misses', 0)
  var lookups: number = cache_hits + cache_misses
  snapshot.avg_ms = renders > 0 ? total_ms / renders : 0.0
  snapshot.cache_hit_percent = lookups > 0 ? cache_hits * 100.0 / lookups : 0.0
  snapshot.cache_entries = len(s_subtree_cache)
  snapshot.epoch = s_render_epoch
  return snapshot
enddef

# 任何不由 SubtreeValid() 覆盖的状态变化都必须走这里:git 状态、未保存标记、
# 过滤条件、根目录切换、整表重置。
def BumpRenderEpoch()
  var invalidations: number = get(s_render_stats, 'invalidations', 0)
  var invalidated_subtrees: number = get(s_render_stats, 'invalidated_subtrees', 0)
  s_render_stats.invalidations = invalidations + 1
  s_render_stats.invalidated_subtrees = invalidated_subtrees + len(s_subtree_cache)
  s_render_epoch += 1
  s_subtree_cache = {}
enddef

# 影响行内容的配置项。每次 Render() 比对一次,变了就整体失效——O(1) 且不会
# 因为用户运行时改配置而渲染出陈旧的图标或后缀。
def RenderConfigSig(): string
  return string([
    !!get(g:, 'simpletree_show_file_icons', 1),
    !!get(g:, 'simpletree_folder_suffix', 1),
    !!get(g:, 'simpletree_show_modified', 1),
    get(g:, 'simpletree_modified_symbol', '●'),
    !!get(g:, 'simpletree_use_nerdfont', 0),
    !!get(g:, 'simpletree_show_bookmarks', 1),
    get(g:, 'simpletree_bookmark_symbol', '★'),
    MarkSymbol(),
    len(s_marked),
    SortMode(),
    !!get(g:, 'simpletree_sort_reverse', 0),
    GitStatusEnabled(),
    GitSymbols(),
    s_icons,
  ])
enddef

def SubtreeValidPath(path: string, depth: number): bool
  # 没有目录缓存时渲染的是 loading/error 占位行,那种情况从不进缓存。
  if !has_key(s_cache, path)
    return false
  endif
  return SubtreeValid(path, depth, s_cache[path])
enddef

def SubtreeValid(path: string, depth: number, entries: list<dict<any>>): bool
  if !has_key(s_subtree_cache, path)
    return false
  endif
  var rec = s_subtree_cache[path]
  if rec.depth != depth || rec.epoch != s_render_epoch
    return false
  endif
  # 目录列表必须是同一个 list 对象且长度未变:流式扫描是往同一个 list 里追加,
  # 只比对象身份会漏掉增量到达的条目。
  if rec.entries isnot entries || rec.count != len(entries)
    return false
  endif
  # 只需要检查目录子节点:文件行的内容完全由 entries 与 epoch 决定。
  for pair in rec.dirs
    if GetNodeState(pair[0]).expanded != pair[1]
      return false
    endif
    if pair[1] && !SubtreeValidPath(pair[0], depth + 1)
      return false
    endif
  endfor
  return true
enddef

def BuildLines(path: string, depth: number, lines: list<string>, idx: list<dict<any>>)
  var rec = BuildSubtree(path, depth)
  if !empty(rec.lines)
    lines->extend(rec.lines)
    idx->extend(rec.idx)
  endif
enddef

def BuildSubtree(path: string, depth: number): dict<any>
  var want = GetNodeState(path).expanded
  if !want
    return {lines: [], idx: []}
  endif

  var hasCache = has_key(s_cache, path)
  var isLoading = get(s_loading, path, v:false)

  if !hasCache
    # 占位行随扫描进度频繁变化,不值得缓存,也只有一行。
    if has_key(s_scan_errors, path)
      var message = strcharpart(substitute(s_scan_errors[path], '[\r\n]', ' ', 'g'), 0, 100)
      return {
        lines: [repeat('  ', depth) .. '! ' .. message],
        idx: [{path: '', is_dir: false, name: '', depth: depth, error: true}],
      }
    endif
    if !isLoading
      ScanDirAsync(path)
    endif
    return {
      lines: [repeat('  ', depth) .. s_icons.loading .. ' Loading...'],
      idx: [{path: '', is_dir: false, name: '', depth: depth, loading: true}],
    }
  endif

  var entries = s_cache[path]
  if !s_render_cache_off && SubtreeValid(path, depth, entries)
    var cache_hits: number = get(s_render_stats, 'cache_hits', 0)
    s_render_stats.cache_hits = cache_hits + 1
    return s_subtree_cache[path]
  endif
  if !s_render_cache_off
    var cache_misses: number = get(s_render_stats, 'cache_misses', 0)
    s_render_stats.cache_misses = cache_misses + 1
  endif

  var lines: list<string> = []
  var idx: list<dict<any>> = []
  var dirs: list<list<any>> = []

  var show_icons = !!get(g:, 'simpletree_show_file_icons', 1)
  var show_suffix = !!get(g:, 'simpletree_folder_suffix', 1)
  var show_modified = !!get(g:, 'simpletree_show_modified', 1)
  var git_symbols = GitSymbols()
  var modified_symbol = get(g:, 'simpletree_modified_symbol', '●')
  var show_bookmarks = !!get(g:, 'simpletree_show_bookmarks', 1)
  var bookmark_symbol = get(g:, 'simpletree_bookmark_symbol', '★')
  var has_marks = !empty(s_marked)
  var mark_symbol = MarkSymbol()
  var indent = repeat('  ', depth)
  if show_bookmarks
    LoadBookmarks()
  endif
  for e in SortedEntries(entries)
    if !FilterAllowsEntry(e)
      continue
    endif
    var expanded = false
    var icon = ''
    if e.is_dir
      expanded = GetNodeState(e.path).expanded
      icon = expanded ? s_icons.dir_open : s_icons.dir
      dirs->add([e.path, expanded])
    else
      icon = show_icons ? FileIcon(e.name) : s_icons.file
    endif
    var suffix = (e.is_dir && show_suffix) ? '/' : ''
    # 未保存标记走事件维护的 path 字典，渲染期零 buffer 查询。
    var modified = !e.is_dir && show_modified && get(s_modified_paths, e.path, v:false)
    var decoration = modified ? (' ' .. modified_symbol) : ''
    var git_code = GitCodeFor(e.path)
    if git_code !=# ''
      decoration ..= ' ' .. get(git_symbols, git_code[0], git_code[0])
    endif
    var bookmarked = show_bookmarks && IsBookmarked(e.path)
    if bookmarked
      decoration ..= ' ' .. bookmark_symbol
    endif
    var marked = has_marks && IsMarked(e.path)
    if marked
      decoration ..= ' ' .. mark_symbol
    endif

    lines->add(indent .. icon .. ' ' .. e.name .. suffix .. decoration)
    idx->add({path: e.path, is_dir: e.is_dir, name: e.name, depth: depth,
      modified: modified, git: git_code, bookmarked: bookmarked, marked: marked})

    if expanded
      var sub = BuildSubtree(e.path, depth + 1)
      if !empty(sub.lines)
        lines->extend(sub.lines)
        idx->extend(sub.idx)
      endif
    endif
  endfor

  var rec = {
    depth: depth,
    epoch: s_render_epoch,
    entries: entries,
    count: len(entries),
    dirs: dirs,
    lines: lines,
    idx: idx,
  }
  if !s_render_cache_off
    s_subtree_cache[path] = rec
  endif
  return rec
enddef

def RootLabel(): string
  var label = fnamemodify(RStripSlash(s_root), ':t')
  if label ==# ''
    label = s_root
  endif
  return label
enddef

# matchaddpos() 是窗口局部的,所以每个显示这棵树的窗口都要各自维护一个
# match id;只更新当前 tab 会让别的 tab 停留在旧的高亮行上。
def UpdateActiveHighlight()
  PruneTabs()
  if empty(s_tabs)
    return
  endif
  var lnum = s_active_path ==# '' ? 0 : PathLine(NormPath(s_active_path))
  for rec in values(s_tabs)
    if rec.matchid > 0
      try
        call matchdelete(rec.matchid, rec.winid)
      catch
      endtry
      rec.matchid = -1
    endif
    if lnum > 0
      try
        rec.matchid = matchaddpos('SimpleTreeActiveFile', [[lnum]], 5, -1, {window: rec.winid})
      catch
        rec.matchid = -1
      endtry
    endif
  endfor
enddef

# path -> 行号索引。渲染期不再预先构建，第一次查询时按当前 s_line_index 建好
# 并缓存，直到下一次渲染换掉索引为止。
def EnsurePathLines()
  if s_path_lines_gen == s_line_index_gen
    return
  endif
  var pl: dict<number> = {}
  for i in range(len(s_line_index))
    var p = get(s_line_index[i], 'path', '')
    if p !=# '' && !has_key(pl, p)
      pl[p] = i + 1
    endif
  endfor
  s_path_lines = pl
  s_path_lines_gen = s_line_index_gen
enddef

# path -> 行号 O(1)；未命中时回退到规范化比较，兼容大小写/斜杠差异。
def PathLine(path: string): number
  if path ==# ''
    return 0
  endif
  EnsurePathLines()
  var lnum = get(s_path_lines, path, 0)
  if lnum > 0
    return lnum
  endif
  var np = NormPath(path)
  lnum = get(s_path_lines, np, 0)
  if lnum > 0
    return lnum
  endif
  for i in range(len(s_line_index))
    var ep = get(s_line_index[i], 'path', '')
    if ep !=# '' && (ep ==# np || NormPath(ep) ==# np)
      return i + 1
    endif
  endfor
  return 0
enddef

# git 状态用 text properties 按行染色；随 diff 写入后统一重建，避免错位。
def ApplyGitHighlights(out: list<string>)
  if !BufValid()
    return
  endif
  try
    call prop_clear(1, max([1, len(out)]), {bufnr: s_bufnr})
  catch
    return
  endtry
  if empty(s_git_status) || !GitStatusEnabled()
    return
  endif
  for i in range(len(s_line_index))
    var code = get(s_line_index[i], 'git', '')
    if code ==# ''
      continue
    endif
    var type_name = GitPropType(code[0])
    if type_name ==# ''
      continue
    endif
    try
      call prop_add(i + 1, 1, {bufnr: s_bufnr, type: type_name, end_col: strlen(get(out, i, '')) + 1})
    catch
    endtry
  endfor
enddef

def GitPropType(code: string): string
  if code ==# 'M'
    return 'SimpleTreeGitModified'
  elseif code ==# 'S'
    return 'SimpleTreeGitStaged'
  elseif code ==# 'U'
    return 'SimpleTreeGitUntracked'
  elseif code ==# 'C'
    return 'SimpleTreeGitConflict'
  elseif code ==# 'D'
    return 'SimpleTreeGitDeleted'
  endif
  return ''
enddef

# Write `out` into the tree buffer touching only the lines that actually
# changed. The previous approach rewrote every line via setbufline(buf, 1, out)
# on each render — including every streamed chunk during a directory scan and
# every expand/collapse — forcing Vim to re-render and re-syntax the whole
# buffer. Diffing means unchanged rows aren't marked modified, so large trees
# and streaming updates stay smooth.
# 上一次写进树 buffer 的内容。buffer 由本插件独占且 nomodifiable，所以可以拿
# 它当 diff 基准，省掉每次渲染都把上万行读回来的开销；行数对不上就退回真读，
# 保证外部把 buffer 换掉时不会写错。
var s_rendered_lines: list<string> = []
var s_rendered_bufnr: number = -1

def BufferLineCount(): number
  var info = getbufinfo(s_bufnr)
  return len(info) > 0 ? get(info[0], 'linecount', -1) : -1
enddef

def UpdateBufferDiff(out: list<string>)
  var cur: list<string>
  if s_rendered_bufnr == s_bufnr && len(s_rendered_lines) == BufferLineCount()
    cur = s_rendered_lines
  else
    cur = getbufline(s_bufnr, 1, '$')
  endif
  var n_new = len(out)
  var n_cur = len(cur)
  var changed_lines = 0
  var successful_writes = 0
  var all_writes_succeeded = true
  var i = 0
  while i < n_new
    if i < n_cur && cur[i] ==# out[i]
      i += 1
      continue
    endif
    # Start of a run of changed (or newly added) lines; extend until the next
    # line that already matches, then write the whole run in one call.
    var j = i
    while j < n_new && !(j < n_cur && cur[j] ==# out[j])
      j += 1
    endwhile
    try
      var write_result: number = setbufline(s_bufnr, i + 1, out[i : j - 1])
      if write_result == 0
        changed_lines += j - i
        successful_writes += 1
      else
        all_writes_succeeded = false
      endif
    catch
      all_writes_succeeded = false
    endtry
    i = j
  endwhile
  if n_cur > n_new
    try
      if deletebufline(s_bufnr, n_new + 1, n_cur) == 0
        changed_lines += n_cur - n_new
        successful_writes += 1
      else
        all_writes_succeeded = false
      endif
    catch
      all_writes_succeeded = false
    endtry
  endif
  # copy(): 调用方后面还会把 out 交给别的函数，缓存必须是当时的快照。
  # A failed API call means the requested output is not a valid future diff
  # baseline. Read the actual buffer once in that rare path instead.
  s_rendered_lines = all_writes_succeeded ? copy(out) : getbufline(s_bufnr, 1, '$')
  s_rendered_bufnr = s_bufnr
  s_render_stats.last_changed_lines = changed_lines
  var total_changed_lines: number = get(s_render_stats, 'total_changed_lines', 0)
  var buffer_writes: number = get(s_render_stats, 'buffer_writes', 0)
  s_render_stats.total_changed_lines = total_changed_lines + changed_lines
  s_render_stats.buffer_writes = buffer_writes + successful_writes
enddef

def Render()
  if !s_open || s_root ==# ''
    return
  endif
  var render_started = reltime()
  EnsureWindowAndBuffer()

  call EnsureSyntaxTree()

  # 运行时改了图标/后缀之类的配置,整棵缓存作废。O(1),每次渲染只比一次。
  var cfg_sig = RenderConfigSig()
  if cfg_sig !=# s_render_cfg_sig
    s_render_cfg_sig = cfg_sig
    BumpRenderEpoch()
  endif

  var selected = CursorNode()
  var selected_path = get(selected, 'path', '')
  var selected_lnum = CursorLine()
  var lines: list<string> = []
  var idx: list<dict<any>> = []

  var stroot = GetNodeState(s_root)
  var show_root = !!get(g:, 'simpletree_show_root', 1)
  if show_root
    var root_icon = stroot.expanded ? s_icons.dir_open : s_icons.dir
    var root_suffix = !!get(g:, 'simpletree_folder_suffix', 1) ? '/' : ''
    lines->add(root_icon .. ' ' .. RootLabel() .. root_suffix)
    idx->add({path: s_root, is_dir: true, name: RootLabel(), depth: 0, is_root: true})
    BuildLines(s_root, 1, lines, idx)
  else
    stroot.expanded = true
    BuildLines(s_root, 0, lines, idx)
  endif

  if len(lines) == 0 && get(s_loading, s_root, v:false)
    lines = [s_icons.loading .. ' Loading...']
    idx = [{path: '', is_dir: false, name: '', depth: 0, loading: true}]
  endif

  if !BufValid()
    return
  endif

  try
    call setbufvar(s_bufnr, '&modifiable', 1)
  catch
  endtry

  var out = len(lines) == 0 ? [''] : lines
  UpdateBufferDiff(out)

  try
    call setbufvar(s_bufnr, '&modifiable', 0)
  catch
  endtry

  var maxline = max([1, len(out)])
  for winid in TreeWindows()
    try
      call win_execute(winid, 'if line(".") > ' .. maxline .. ' | normal! G | endif')
    catch
    endtry
  endfor

  s_line_index = idx
  # path -> 行号的字典按需构建：一次渲染通常只查一次(恢复光标)，为此建一个
  # 上万条的字典纯属浪费。PathLine() 真要用时才建。
  s_line_index_gen += 1
  ApplyGitHighlights(out)
  if selected_path !=# ''
    # 展开/折叠光标所在目录时它自己的行号不变，先做 O(1) 校验；命中就完全
    # 不必构建 path->行号 字典。
    if selected_lnum <= 0 || selected_lnum > len(idx)
        || get(idx[selected_lnum - 1], 'path', '') !=# selected_path
      FocusPath(selected_path)
    endif
  endif
  UpdateActiveHighlight()

  var last_ms: float = reltimefloat(reltime(render_started)) * 1000.0
  var renders: number = get(s_render_stats, 'renders', 0)
  var total_ms: float = get(s_render_stats, 'total_ms', 0.0)
  var max_ms: float = get(s_render_stats, 'max_ms', 0.0)
  s_render_stats.renders = renders + 1
  s_render_stats.total_ms = total_ms + last_ms
  s_render_stats.last_ms = last_ms
  # max({list<Float>}) only became available in Vim 9.1.1684. SimpleTree still
  # supports Vim 9.0, so keep all newly added timing math on explicit Float
  # comparisons instead of depending on the newer aggregate behavior.
  if last_ms > max_ms
    s_render_stats.max_ms = last_ms
  endif
  s_render_stats.visible_lines = len(out)
enddef

# =============================================================
# 根路径切换与锁定
# =============================================================
def SetRoot(new_root: string, lock: bool = false)
  var nr = CanonDir(new_root)
  if !IsDir(nr)
    echohl ErrorMsg
    echom '[SimpleTree] invalid root: ' .. nr
    echohl None
    return
  endif
  var old_root = s_root
  UnwatchAllDirs()
  # 换根后旧根下的标记不再可见，留着只会让下一次批量操作作用在看不见的路径上。
  ClearMarks()
  s_git_status = {}
  BumpRenderEpoch()
  s_git_repo_root = ''
  s_filter_memo = {}
  BumpRenderEpoch()
  s_root = nr
  if lock
    s_root_locked = true
  endif

  EnsureWindowAndBuffer()
  if !BEnsureBackend()
    echohl ErrorMsg
    echom '[SimpleTree] backend not available'
    echohl None
    return
  endif

  var st = GetNodeState(s_root)
  st.expanded = true

  for [p, id] in items(s_pending)
    try
      BCancel(id)
    catch
    endtry
  endfor
  s_pending = {}
  s_loading = {}
  s_cache = {}
  s_cache_has_metadata = {}
  s_loading_has_metadata = {}
  s_scan_errors = {}
  s_dir_mtimes = {}

  ScanDirAsync(s_root)
  GitStatusRefresh()
  Emit('RootChanged', {root: s_root, old_root: old_root})
  Render()
enddef

export def OnToggleRootLock()
  s_root_locked = !s_root_locked
  echo '[SimpleTree] root lock: ' .. (s_root_locked ? 'ON' : 'OFF')
enddef

def GuardRootLock(): bool
  if s_root_locked
    echo '[SimpleTree] root is locked. Press L to unlock.'
    return true
  endif
  return false
enddef

export def OnRootHere()
  if GuardRootLock()
    return
  endif
  var node = CursorNode()
  if !IsActionableNode(node)
    return
  endif
  var p = node.is_dir ? node.path : fnamemodify(node.path, ':h')
  SetRoot(p)
enddef

export def OnRootUp()
  if GuardRootLock()
    return
  endif
  if s_root ==# ''
    return
  endif

  var cur = CanonDir(s_root)
  var up = ParentDir(cur)

  if RStripSlash(up) ==# RStripSlash(cur)
    return
  endif

  SetRoot(up)
enddef

export def OnRootPrompt()
  if GuardRootLock()
    return
  endif
  var start = s_root !=# '' ? s_root : getcwd()
  var inp = input('SimpleTree new root: ', start, 'dir')
  if inp ==# ''
    return
  endif
  SetRoot(inp)
enddef

export def OnRootCwd()
  if GuardRootLock()
    return
  endif
  SetRoot(getcwd())
enddef

export def OnRootCurrent()
  if s_root_locked
    echo '[SimpleTree] root is locked. Press L to unlock.'
    return
  endif

  var ap = ''
  var other = OtherWindowId()
  if other != 0
    var wi = getwininfo(other)
    if len(wi) > 0
      var obuf = wi[0].bufnr
      var oname = bufname(obuf)
      var cand = fnamemodify(oname, ':p')
      if cand !=# '' && filereadable(cand)
        ap = cand
      endif
    endif
  endif

  if ap ==# ''
    var cur = expand('%:p')
    if cur !=# '' && filereadable(cur)
      ap = fnamemodify(cur, ':p')
    endif
  endif

  var p = (ap ==# '') ? getcwd() : fnamemodify(ap, ':h')
  SetRoot(p)
enddef

# 打印当前上下文：当前根/锁、树窗口、另一个窗口及其文件
def DebugContext(tag: string): void
  var curbuf = bufnr('%')
  var curbufname = bufname(curbuf)
  var other = OtherWindowId()
  Log(printf('CTX[%s] root="%s" locked=%s tree_win=%d curbuf=%d curbufname="%s" other_win=%d',
    tag, s_root, (s_root_locked ? 'true' : 'false'), s_winid, curbuf, curbufname, other), 'MoreMsg')
  if other != 0
    var w = getwininfo(other)
    if len(w) > 0
      var obuf = w[0].bufnr
      var oname = bufname(obuf)
      var ap = fnamemodify(oname, ':p')
      Log(printf('CTX[%s] other: bufnr=%d name="%s" abs="%s" readable=%s',
        tag, obuf, oname, ap, (filereadable(ap) ? 'true' : 'false')), 'MoreMsg')
    endif
  endif
enddef

# =============================================================
# 用户交互（导出）
# =============================================================
# 自动跟随当前 buffer：在切换到普通文件缓冲区时，若树已打开则 Reveal
export def AutoFollow()
  # 树未打开或未设置根则忽略
  if !WinValid() || s_root ==# ''
    return
  endif

  # 当前在树窗口内，不跟随
  if win_getid() == s_winid
    return
  endif

  # 只处理普通缓冲区（buftype 为空）
  var bt = &buftype
  if type(bt) != v:t_string || bt !=# ''
    return
  endif

  var curf = expand('%:p')
  if curf ==# '' || !filereadable(curf)
    return
  endif
  var ap = AbsPath(curf)
  s_active_path = ap
  s_target_winid = win_getid()

  # 若文件在根之下，直接 Reveal
  if IsSubPath(s_root, ap)
    RevealPath(ap)
    return
  endif

  # 文件不在当前根下：根据配置决定是否自动切根
  if !!get(g:, 'simpletree_auto_follow_change_root', 0)
    if s_root_locked
      Log('AutoFollow: root locked; skip changing root', 'WarningMsg')
      return
    endif
    # 切根到当前文件所在目录，并 Reveal 到文件
    var new_root = fnamemodify(ap, ':h')
    if IsDir(new_root)
      SetRoot(new_root)
      RevealPath(ap)
    endif
  else
    # 不切根时，若文件超出当前根，仅在日志中提示（debug 模式）
    Log('AutoFollow: file outside root; no change', 'Comment')
  endif
enddef

def CursorLine(): number
  if !WinValid()
    return 0
  endif
  var pos = getcurpos(s_winid)
  return len(pos) > 1 ? pos[1] : 0
enddef

def CursorNode(): dict<any>
  if !WinValid()
    return {}
  endif
  var pos = getcurpos(s_winid)
  var lnum = len(pos) > 1 ? pos[1] : 0
  if lnum <= 0 || lnum > len(s_line_index)
    return {}
  endif
  var node = s_line_index[lnum - 1]
  return node
enddef

# 不再在找不到目标时跳到顶部，保持当前位置
def FocusPath(path: string): void
  if !WinValid() || path ==# ''
    return
  endif
  var target = PathLine(path)
  if target > 0
    try | call win_execute(s_winid, 'normal! ' .. target .. 'G') | catch | endtry
  endif
enddef

def FocusFirstChild(dir_path: string): void
  if !WinValid()
    return
  endif
  var idx_dir = -1
  var dir_depth = -1
  for i in range(len(s_line_index))
    if get(s_line_index[i], 'path', '') ==# dir_path
      idx_dir = i
      dir_depth = get(s_line_index[i], 'depth', -1)
      break
    endif
  endfor
  if idx_dir < 0
    return
  endif
  var next_idx = idx_dir + 1
  if next_idx < len(s_line_index)
    var next = s_line_index[next_idx]
    if get(next, 'depth', -1) == dir_depth + 1
      try
        call win_execute(s_winid, 'normal! ' .. (next_idx + 1) .. 'G')
      catch
      endtry
    endif
  endif
enddef

# 折叠最近的已展开祖先
def CollapseNearestExpandedAncestor(path: string): void
  var p = fnamemodify(path, ':h')
  while p !=# ''
    if p ==# s_root
      return
    endif
    if GetNodeState(p).expanded
      ToggleDir(p)
      FocusPath(p)
      return
    endif
    var nextp = fnamemodify(p, ':h')
    if nextp ==# p
      break
    endif
    p = nextp
  endwhile
  var parent = fnamemodify(path, ':h')
  if parent !=# '' && parent !=# s_root
    FocusPath(parent)
  endif
enddef

def ToggleDir(path: string)
  var st = GetNodeState(path)
  st.expanded = !st.expanded
  if st.expanded
    if !has_key(s_cache, path) && !get(s_loading, path, v:false)
      ScanDirAsync(path)
    else
      WatchDir(path)
    endif
    Emit('DirExpanded', {path: path})
  else
    UnwatchDir(path)
    Emit('DirCollapsed', {path: path})
  endif
  Render()
enddef

def OpenFile(p: string)
  if p ==# ''
    return
  endif
  # keep_in_file = 1 表示打开后保持在文件窗口
  var keep_in_file = !!get(g:, 'simpletree_keep_focus', 1)

  var target_win = ResolveTargetWindow()
  if target_win < 0
    return
  endif

  if target_win != 0
    call win_gotoid(target_win)
    execute 'edit ' .. fnameescape(p)
  else
    # 无候选或选择了“新建分屏”时，右侧新建分屏并打开
    if !!get(g:, 'simpletree_split_force_right', 1)
      execute 'belowright vsplit'
    else
      execute 'vsplit'
    endif
    execute 'edit ' .. fnameescape(p)
    s_target_winid = win_getid()
  endif
  s_active_path = AbsPath(p)
  Emit('NodeOpened', {path: s_active_path})

  # 只有在不需要保持在文件窗口时，才回到树窗口
  if !keep_in_file && WinValid()
    call win_gotoid(s_winid)
  endif
enddef

export def OnEnter()
  var node = CursorNode()
  if !IsActionableNode(node)
    return
  endif
  if node.is_dir
    ToggleDir(node.path)
  else
    OpenFile(node.path)
  endif
enddef

# l：目录上展开并定位第一个子项；文件上打开文件
export def OnExpand()
  var node = CursorNode()
  if !IsActionableNode(node)
    return
  endif
  if node.is_dir
    if !GetNodeState(node.path).expanded
      ToggleDir(node.path)
    endif
    FocusFirstChild(node.path)
  else
    OpenFile(node.path)
  endif
enddef

# h：目录已展开时折叠当前；目录已折叠或文件时折叠最近的已展开父目录
export def OnCollapse()
  var node = CursorNode()
  if !IsActionableNode(node)
    return
  endif
  if node.is_dir
    if GetNodeState(node.path).expanded
      ToggleDir(node.path)
    else
      var parent = fnamemodify(node.path, ':h')
      if parent ==# s_root
        return
      endif
      CollapseNearestExpandedAncestor(node.path)
    endif
  else
    CollapseNearestExpandedAncestor(node.path)
  endif
enddef

# 一键折叠根下所有目录
export def OnCollapseAll()
  if s_root ==# ''
    echo '[SimpleTree] root not set'
    return
  endif
  var count = 0
  # 关闭所有已展开（不含 root）
  for [p, st] in items(s_state)
    if p !=# s_root && get(st, 'expanded', v:false)
      s_state[p].expanded = false
      count += 1
    endif
  endfor
  # 取消所有非 root 的挂起请求与加载标记
  for [p, id] in items(s_pending)
    if p !=# s_root
      try | BCancel(id) | catch | endtry
    endif
  endfor
  s_pending = filter(s_pending, (k, _) => k ==# s_root)
  s_loading = filter(s_loading, (k, _) => k ==# s_root)
  s_loading_has_metadata = filter(s_loading_has_metadata, (k, _) => k ==# s_root)
  for p in keys(s_watched)
    if p !=# s_root
      UnwatchDir(p)
    endif
  endfor

  Render()
  echo '[SimpleTree] collapsed all under root (' .. count .. ' dirs)'
enddef

export def OnRefresh()
  Refresh()
enddef

export def OnToggleHidden()
  s_hide_dotfiles = !s_hide_dotfiles
  g:simpletree_hide_dotfiles = s_hide_dotfiles ? 1 : 0
  Refresh()
enddef

export def OnToggleGitIgnore()
  s_git_ignore = !s_git_ignore
  g:simpletree_git_ignore = s_git_ignore ? 1 : 0
  Refresh()
enddef

export def CompleteSort(arglead: string, _cmdline: string, _cursorpos: number): list<string>
  var lead = tolower(arglead)
  return SORT_MODES->copy()->filter((_, mode) => stridx(mode, lead) == 0)
enddef

export def SetSort(requested: string = '')
  var old_mode = SortMode()
  var mode = tolower(trim(requested))
  if mode ==# ''
    mode = SORT_MODES[(index(SORT_MODES, old_mode) + 1) % len(SORT_MODES)]
  elseif index(SORT_MODES, mode) < 0
    echohl WarningMsg
    echom '[SimpleTree] unknown sort mode: ' .. requested .. ' (use name, extension, mtime or size)'
    echohl None
    return
  endif
  g:simpletree_sort = mode
  BumpRenderEpoch()
  if SortNeedsMetadata(mode) && !CachedSnapshotsHaveMetadata()
    # 当前快照确实缺 metadata 时才重扫；rich snapshot 在模式间切换时复用。
    Refresh()
  else
    Render()
  endif
  echo '[SimpleTree] sort: ' .. mode .. (get(g:, 'simpletree_sort_reverse', 0) ? ' (reversed)' : '')
enddef

export def OnSortCycle()
  SetSort()
enddef

export def ToggleSortReverse()
  g:simpletree_sort_reverse = get(g:, 'simpletree_sort_reverse', 0) ? 0 : 1
  BumpRenderEpoch()
  Render()
  echo '[SimpleTree] sort reverse: ' .. (g:simpletree_sort_reverse ? 'on' : 'off')
enddef

export def OnClose()
  Close()
enddef

# 树 buffer 只有一个,被 wipe 说明最后一个窗口也没了——整个会话结束,
# 所有 tab 的记录一起作废。
export def OnBufWipe()
  EndFrontendSession()
  s_tabs = {}
  s_winid = 0
  s_bufnr = -1
enddef

# ===== 文件操作：复制/剪切/粘贴/新建/重命名/删除 =====
export def OnCopy()
  var targets = ActionTargets()
  if empty(targets)
    echo '[SimpleTree] nothing to copy'
    return
  endif
  s_clipboard = {mode: 'copy', items: targets}
  echo len(targets) == 1
    ? ('[SimpleTree] copy: ' .. targets[0])
    : printf('[SimpleTree] copy %d items: %s', len(targets), SummarizePaths(targets))
enddef

export def OnCut()
  var targets = ActionTargets()
  if empty(targets)
    echo '[SimpleTree] nothing to cut'
    return
  endif
  # 标记集合里根目录已经被 MarkPath() 挡住了，这里挡的是光标落在根节点上。
  if targets->copy()->filter((_, p) => PathEq(p, s_root))->len() > 0
    echo '[SimpleTree] workspace root cannot be moved'
    return
  endif
  s_clipboard = {mode: 'cut', items: targets}
  echo len(targets) == 1
    ? ('[SimpleTree] cut: ' .. targets[0])
    : printf('[SimpleTree] cut %d items: %s', len(targets), SummarizePaths(targets))
enddef

export def OnPaste()
  if type(s_clipboard) != v:t_dict || get(s_clipboard, 'mode', '') ==# '' || len(get(s_clipboard, 'items', [])) == 0
    echo '[SimpleTree] clipboard empty'
    return
  endif
  var node = CursorNode()
  if !IsActionableNode(node)
    echo '[SimpleTree] no target selected'
    return
  endif
  var destDir = TargetDirForNode(node)
  if destDir ==# '' || !isdirectory(destDir)
    echo '[SimpleTree] invalid target directory'
    return
  endif
  if !WorkspaceContainsOperationPath(destDir)
    echohl ErrorMsg | echom '[SimpleTree] refusing to write through a directory link outside the workspace' | echohl None
    return
  endif

  var mode = s_clipboard.mode
  var srcs: list<string> = copy(s_clipboard.items)
  var focused = ''
  var remaining: list<string> = []

  for src in srcs
    if !PathExists(src)
      echo '[SimpleTree] skip missing: ' .. src
      if mode ==# 'cut'
        remaining->add(src)
      endif
      continue
    endif
    var base = fnamemodify(src, ':t')
    var source_type = getftype(src)
    var source_is_link = source_type ==# 'link'
    # A directory symlink is still a link object for copy/move semantics.
    var source_subtree = source_type ==# 'dir'
    if !WorkspaceContainsOperationPath(src, true)
      echohl ErrorMsg | echom '[SimpleTree] source resolves outside the workspace' | echohl None
      if mode ==# 'cut'
        remaining->add(src)
      endif
      continue
    endif
    if source_type ==# 'dir'
      && IsSubPath(ResolvedNormPath(src), ResolvedNormPath(destDir))
      echohl WarningMsg | echom '[SimpleTree] cannot paste a directory into itself' | echohl None
      if mode ==# 'cut'
        remaining->add(src)
      endif
      continue
    endif
    if mode ==# 'cut'
        && RefuseModifiedBuffers(src, source_subtree, 'move', !source_is_link)
      remaining->add(src)
      continue
    endif
    var proposed = PathJoin(destDir, base)
    var dst = ''
    var same_target = PathEq(src, proposed)
      || PathEq(ResolvedNormPath(src), ResolvedNormPath(proposed))
    if same_target
      if mode ==# 'cut'
        echo '[SimpleTree] source is already in the target directory'
        remaining->add(src)
        continue
      endif
      dst = AskUniqueName(destDir, base .. ' copy')
    else
      dst = ResolveConflict(destDir, base)
    endif
    if dst ==# ''
      echo '[SimpleTree] skip: ' .. base
      if mode ==# 'cut'
        remaining->add(src)
      endif
      continue
    endif
    if !IsSubPath(destDir, dst) || PathEq(destDir, dst)
      echohl ErrorMsg | echom '[SimpleTree] target must stay inside destination directory' | echohl None
      if mode ==# 'cut'
        remaining->add(src)
      endif
      continue
    endif
    var target_is_link = getftype(dst) ==# 'link'
    var target_was_dir = getftype(dst) ==# 'dir'
    var destination_buffer_subtree = source_subtree || target_was_dir
    if RefuseModifiedBuffers(dst, destination_buffer_subtree, 'replace', !target_is_link)
      if mode ==# 'cut'
        remaining->add(src)
      endif
      continue
    endif

    var rename_plan: list<dict<any>> = mode ==# 'cut'
      ? BufferRenamePlan(src, dst, source_subtree)
      : []
    var transfer = mode ==# 'cut'
      ? MovePathSafely(src, dst)
      : CopyPathSafely(src, dst)
    if transfer.installed
      # 关闭被替换目标的未修改缓冲区，再把成功移动的源缓冲区改到新路径。
      WipeBuffersForPath(dst, destination_buffer_subtree,
        !target_is_link && !source_is_link)
      if mode ==# 'cut' && transfer.source_removed
        ApplyBufferRenamePlan(rename_plan)
      endif
      focused = dst
      InvalidateAndRescan(destDir)
      if mode ==# 'cut'
        var sp = fnamemodify(src, ':h')
        if sp !=# destDir
          InvalidateAndRescan(sp)
        endif
        if transfer.source_removed
          echo '[SimpleTree] moved: ' .. base .. ' -> ' .. destDir
        else
          remaining->add(src)
          echohl WarningMsg
          echom '[SimpleTree] copied safely, but source was not fully removed: ' .. src
          echohl None
        endif
      else
        echo '[SimpleTree] copied: ' .. base .. ' -> ' .. destDir
      endif
    else
      echohl ErrorMsg
      echom '[SimpleTree] failed to ' .. (mode ==# 'copy' ? 'copy' : 'move') .. ': ' .. src
      echohl None
      if mode ==# 'cut'
        remaining->add(src)
      endif
    endif
  endfor

  # 粘贴成功后标记就过期了：源路径在 cut 之后已经不存在，留着只会让下一个
  # 操作作用在一批幽灵路径上。
  if focused !=# ''
    ClearMarks()
  endif
  Render()
  if focused !=# ''
    RevealPath(focused)
  endif

  if mode ==# 'cut'
    s_clipboard = len(remaining) == 0
      ? {mode: '', items: []}
      : {mode: 'cut', items: remaining}
  endif
enddef

export def OnNewFile()
  var node = CursorNode()
  if !IsActionableNode(node)
    echo '[SimpleTree] no target selected'
    return
  endif
  var destDir = TargetDirForNode(node)
  if destDir ==# '' || !isdirectory(destDir)
    echo '[SimpleTree] invalid target directory'
    return
  endif
  if !WorkspaceContainsOperationPath(destDir)
    echohl ErrorMsg | echom '[SimpleTree] refusing to create through a directory link outside the workspace' | echohl None
    return
  endif
  var raw_name = input('New file name: ', '')
  if trim(raw_name) ==# ''
    return
  endif
  var name = SafeRelativeName(raw_name)
  if name ==# ''
    echohl ErrorMsg | echom '[SimpleTree] enter a relative path without . or .. segments' | echohl None
    return
  endif
  var dst = AskUniqueName(destDir, name)
  if dst ==# ''
    return
  endif
  var parent = fnamemodify(dst, ':h')
  if !EnsureWorkspaceDirectory(parent)
    echohl ErrorMsg
    echom '[SimpleTree] refusing to create through a path that leaves the workspace'
    echohl None
    return
  endif
  try
    if writefile([], dst, 'b') != 0
      echohl ErrorMsg | echom '[SimpleTree] create file failed: ' .. dst | echohl None
      return
    endif
  catch
    echohl ErrorMsg | echom '[SimpleTree] create file exception: ' .. v:exception | echohl None
    return
  endtry
  echo '[SimpleTree] created file: ' .. dst
  Emit('FileCreated', {path: dst, is_dir: false})
  InvalidateAndRescan(destDir)
  Render()
  RevealPath(dst)
  if !!get(g:, 'simpletree_open_on_create', 1)
    OpenFile(dst)
  endif
enddef

export def OnNewFolder()
  var node = CursorNode()
  if !IsActionableNode(node)
    echo '[SimpleTree] no target selected'
    return
  endif
  var destDir = TargetDirForNode(node)
  if destDir ==# '' || !isdirectory(destDir)
    echo '[SimpleTree] invalid target directory'
    return
  endif
  if !WorkspaceContainsOperationPath(destDir)
    echohl ErrorMsg | echom '[SimpleTree] refusing to create through a directory link outside the workspace' | echohl None
    return
  endif
  var raw_name = input('New folder name: ', '')
  if trim(raw_name) ==# ''
    return
  endif
  var name = SafeRelativeName(raw_name)
  if name ==# ''
    echohl ErrorMsg | echom '[SimpleTree] enter a relative path without . or .. segments' | echohl None
    return
  endif
  var dst = AskUniqueName(destDir, name)
  if dst ==# ''
    return
  endif
  if !EnsureWorkspaceDirectory(dst)
    echohl ErrorMsg
    echom '[SimpleTree] refusing to create through a path that leaves the workspace'
    echohl None
    return
  endif
  echo '[SimpleTree] created folder: ' .. dst
  Emit('FileCreated', {path: dst, is_dir: true})
  InvalidateAndRescan(destDir)
  Render()
  RevealPath(dst)
enddef

export def OnRename()
  var node = CursorNode()
  if !IsActionableNode(node)
    echo '[SimpleTree] nothing to rename'
    return
  endif
  if get(node, 'is_root', v:false)
    echo '[SimpleTree] workspace root cannot be renamed here'
    return
  endif
  var src = node.path
  if !WorkspaceContainsOperationPath(src, true)
    echohl ErrorMsg | echom '[SimpleTree] refusing to rename a path that resolves outside the workspace' | echohl None
    return
  endif
  var parent = fnamemodify(src, ':h')
  var base = fnamemodify(src, ':t')
  var newname = input('Rename to: ', base)
  if newname ==# ''
    return
  endif
  if SafeLeafName(newname) ==# ''
    echohl ErrorMsg | echom '[SimpleTree] enter a single safe file name (not . or ..)' | echohl None
    return
  endif
  var dst = PathJoin(parent, newname)
  if dst ==# src
    return
  endif
  if !IsSubPath(parent, dst) || PathEq(parent, dst) || !PathEq(fnamemodify(dst, ':h'), parent)
    echohl ErrorMsg | echom '[SimpleTree] rename target must stay in the same directory' | echohl None
    return
  endif

  var source_type = getftype(src)
  var source_is_link = source_type ==# 'link'
  var subtree = source_type ==# 'dir'
  if RefuseModifiedBuffers(src, subtree, 'rename', !source_is_link)
    return
  endif
  var target_is_link = getftype(dst) ==# 'link'
  var target_was_dir = getftype(dst) ==# 'dir'
  var destination_buffer_subtree = subtree || target_was_dir
  if !PathEq(src, dst)
      && RefuseModifiedBuffers(dst, destination_buffer_subtree, 'replace', !target_is_link)
    return
  endif
  var rename_plan = BufferRenamePlan(src, dst, subtree)

  var replacing = PathExists(dst) && !PathEq(src, dst)
  if replacing
    var ans = input('Target exists. Overwrite? [y]es/[n]o: ')
    if ans !=# 'y' && ans !=# 'Y'
      echo '[SimpleTree] rename canceled'
      return
    endif
  endif

  if RenamePathSafely(src, dst)
    echo '[SimpleTree] renamed: ' .. base .. ' -> ' .. newname
    if !PathEq(src, dst)
      WipeBuffersForPath(dst, destination_buffer_subtree,
        !target_is_link && !source_is_link)
    endif
    ApplyBufferRenamePlan(rename_plan)
    Emit('FileRenamed', {old: src, new: dst})
    InvalidateAndRescan(parent)
    Render()
    RevealPath(dst)
  else
    echohl ErrorMsg | echom '[SimpleTree] rename failed' | echohl None
  endif
enddef

# 删除单个已确认的路径。确认框可能开了任意长时间，所以每一条破坏性守卫都在
# 这里对活的条目重新验证一次——批量删除让这段间隔更长，不是更短。
# 返回 {removed, trashed, parent, reason}；reason 非空表示这一项被拒绝或失败，
# 批量路径把它们汇总后一次性报出来。
def DeleteOneConfirmed(path: string, can_trash: bool): dict<any>
  var result = {removed: false, trashed: false, parent: fnamemodify(path, ':h'), reason: ''}
  if !PathExists(path) || !WorkspaceContainsOperationPath(path, true)
    result.reason = 'path changed; refusing to delete'
    return result
  endif
  var path_type = getftype(path)
  var path_is_link = path_type ==# 'link'
  var subtree = path_type ==# 'dir'
  if RefuseModifiedBuffers(path, subtree, 'delete', !path_is_link)
    result.reason = 'unsaved buffer'
    return result
  endif

  var trashed = can_trash && MoveToTrash(path)
  var removed = trashed
  if can_trash && !trashed
    var fallback = exists('*confirm')
      ? confirm('Move to trash failed. Permanently delete instead?', "&Delete\n&Cancel", 2) == 1
      : input('Move to trash failed. Permanently delete? [y/N]: ') =~? '^y'
    if !fallback
      result.reason = 'canceled'
      return result
    endif
    # The fallback confirmation is another unbounded pause. Do not apply the
    # earlier decision to a path that was replaced while the prompt was open.
    if !PathExists(path) || !WorkspaceContainsOperationPath(path, true)
      result.reason = 'path changed; refusing permanent delete'
      return result
    endif
    path_type = getftype(path)
    path_is_link = path_type ==# 'link'
    subtree = path_type ==# 'dir'
    if RefuseModifiedBuffers(path, subtree, 'delete', !path_is_link)
      result.reason = 'unsaved buffer'
      return result
    endif
  endif
  if !removed
    removed = DeletePathRecursive(path)
    if !removed
      result.reason = 'delete failed'
      return result
    endif
  endif
  # 只关闭未修改缓冲区；modified 已在操作前硬性拒绝。
  WipeBuffersForPath(path, subtree, !path_is_link)
  Emit('FileDeleted', {path: path, trashed: trashed})
  result.removed = true
  result.trashed = trashed
  return result
enddef

export def OnDelete()
  var targets = ActionTargets()
  if empty(targets)
    echo '[SimpleTree] nothing to delete'
    return
  endif

  # 确认之前先筛一遍：根目录、已消失的路径和解析后跑出工作区的路径不进提示框，
  # 否则用户是在为一份他不会得到的清单点 Yes。
  var deletable: list<string> = []
  for p in targets
    if p ==# '' || PathEq(p, s_root)
      echohl WarningMsg | echom '[SimpleTree] refusing to delete workspace root' | echohl None
      continue
    endif
    if !PathExists(p)
      echo '[SimpleTree] path not exists: ' .. p
      continue
    endif
    if !WorkspaceContainsOperationPath(p, true)
      echohl ErrorMsg | echom '[SimpleTree] refusing to delete a path that resolves outside the workspace: ' .. p | echohl None
      continue
    endif
    if RefuseModifiedBuffers(p, getftype(p) ==# 'dir', 'delete', getftype(p) !=# 'link')
      continue
    endif
    deletable->add(p)
  endfor
  if empty(deletable)
    return
  endif

  var can_trash = len(TrashCommand(deletable[0])) > 0
  var action = can_trash ? 'Move to trash' : 'Permanently delete'
  var msg = len(deletable) == 1
    ? printf('%s %s "%s" ?', action,
        (getftype(deletable[0]) ==# 'dir' ? 'directory' : 'file'), deletable[0])
    : printf('%s %d items: %s ?', action, len(deletable), SummarizePaths(deletable))
  var ok = 0
  if exists('*confirm')
    ok = (confirm(msg, "&Yes\n&No", 2) == 1) ? 1 : 0
  else
    ok = (input(msg .. ' [y/N]: ') =~? '^y') ? 1 : 0
  endif
  if !ok
    echo '[SimpleTree] delete canceled'
    return
  endif

  var parents: dict<bool> = {}
  var removed: list<string> = []
  var trashed_count = 0
  var failures: list<string> = []
  for p in deletable
    var outcome = DeleteOneConfirmed(p, can_trash)
    if outcome.removed
      removed->add(p)
      if outcome.trashed
        trashed_count += 1
      endif
      if has_key(s_marked, p)
        remove(s_marked, p)
        BumpRenderEpoch()
      endif
      if outcome.parent !=# ''
        parents[outcome.parent] = true
      endif
    else
      failures->add(fnamemodify(RStripSlash(p), ':t') .. ': ' .. outcome.reason)
    endif
  endfor

  for parent in keys(parents)
    InvalidateAndRescan(parent)
  endfor
  Render()

  if !empty(failures)
    echohl ErrorMsg
    echom printf('[SimpleTree] %d of %d not deleted: %s',
      len(failures), len(deletable), join(failures[0 : 4], '; '))
    echohl None
  endif
  if empty(removed)
    return
  endif
  if len(removed) == 1
    echo '[SimpleTree] ' .. (trashed_count > 0 ? 'moved to trash: ' : 'deleted: ') .. removed[0]
  else
    echo printf('[SimpleTree] deleted %d items (%d to trash)', len(removed), trashed_count)
  endif
  var focus = fnamemodify(removed[0], ':h')
  if focus !=# ''
    RevealPath(focus)
  endif
enddef

# ====== 帮助面板（?）======
def BuildHelpLines(): list<string>
  var ca_key = get(g:, 'simpletree_collapse_all_key', 'z')
  return [
    'SimpleTree 快捷键说明',
    '----------------------------------------',
    '<CR>/o/双击  打开文件 / 展开或折叠目录',
    'l/→           展开目录 / 打开文件',
    'h/←/<BS>      折叠当前目录或最近的已展开祖先',
    'R     刷新树（仅重扫缓存）',
    'H     显示/隐藏点文件',
    'I     切换 gitignore 过滤（显示/隐藏被 git 忽略的文件）',
    's     循环排序：name / extension / mtime / size',
    'gs    反转当前排序',
    'q     关闭树窗口',
    'e     将当前节点设为根（目录；文件取父目录））',
    'U     根上移一层',
    'C     输入路径作为根',
    '.     使用当前工作目录作为根',
    'd     使用当前文件所在目录作为根',
    'L     切换根锁定',
    'c     复制当前节点（文件/目录）',
    'x     剪切当前节点（文件/目录）',
    'p     粘贴到当前选中目录（或文件的父目录）',
    'a     在目标目录中新建文件',
    'n     在目标目录中新建文件',
    'A     在目标目录中新建文件夹',
    'N     在目标目录中新建文件夹',
    'r     重命名当前节点',
    'D     删除当前节点（目录为递归删除）',
    'V     垂直分屏打开文件',
    'S     水平分屏打开文件',
    't     在新标签页打开文件',
    'P     预览文件并保持树焦点',
    'f     定位当前编辑文件',
    'y     复制文件名到寄存器',
    'Y     复制完整路径到寄存器',
    'gx    用系统默认程序打开',
    ca_key .. '     一键折叠根下所有目录',
    'F     过滤已加载节点（空串清除）',
    '/     按名称查找并跳转；]f/[f 下一个/上一个匹配',
    '<Space> 标记/取消标记当前节点（可视模式下按整段选区标记）',
    'gm    标记当前节点的全部可见同级节点',
    'gM    清除全部标记',
    '?     显示/关闭本帮助面板',
    '----------------------------------------',
    '提示：新建支持 foo/bar.ext；删除优先移到系统回收站；剪切成功后自动清空剪贴板。',
    '有标记时 c/x/D 作用于整个标记集合，否则作用于光标所在节点。',
    '按键可用 g:simpletree_mappings 自定义；此帮助显示默认键位。',
  ]
enddef

def HelpWinValid(): bool
  return s_help_winid != 0 && win_id2win(s_help_winid) > 0
enddef

# 关闭帮助：同时支持浮窗和分屏
def CloseHelp()
  if s_help_popupid != 0 && exists('*popup_close')
    try
      call popup_close(s_help_popupid)
    catch
    endtry
    s_help_popupid = 0
    s_help_bufnr = -1
    return
  endif

  if s_help_winid != 0 && win_id2win(s_help_winid) > 0
    try
      call win_execute(s_help_winid, 'close')
    catch
    endtry
  endif
  s_help_winid = 0
  s_help_bufnr = -1
enddef

# 浮窗优先的帮助显示（不使用 popup_getbuf，修复 E117）
export def ShowHelp()
  if s_help_popupid != 0 && exists('*popup_close')
    CloseHelp()
    return
  endif

  var lines = BuildHelpLines()

  if exists('*popup_create')
    var width = 0
    for l in lines
      width = max([width, strdisplaywidth(l)])
    endfor
    var height = min([max([10, len(lines) + 2]), 30])
    width += 6

    var popid = popup_create(lines, {
      title: NFEnabled() ? '󰙎 SimpleTree Help' : 'SimpleTree Help',
      pos: 'center',
      minwidth: width,
      minheight: height,
      padding: [0, 2, 0, 2],
      border: [1, 1, 1, 1],
      borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      zindex: 200,
      mapping: 0,
      filter: (id, key) => {
        if key ==# 'q' || key ==# "\<Esc>"
          try
            popup_close(id)
          catch
          endtry
          s_help_popupid = 0
          s_help_bufnr = -1
          return 1
        endif
        return 0
      }
    })

    s_help_popupid = popid
    s_help_bufnr = -1

    if exists('*popup_setoptions')
      try
        call popup_setoptions(popid, {
          highlight: 'Normal',
          borderhighlight: ['FloatBorder']
        })
      catch
      endtry
    endif

    if WinValid()
      call win_gotoid(s_winid)
    endif
    return
  endif

  var height = min([max([10, len(lines) + 2]), 30])
  execute 'botright split'
  execute printf('resize %d', height)
  s_help_winid = win_getid()
  call win_execute(s_help_winid, 'silent enew')
  s_help_bufnr = winbufnr(s_help_winid)
  call win_execute(s_help_winid, 'file SimpleTree Help')
  var opts = [
    'setlocal buftype=nofile',
    'setlocal bufhidden=wipe',
    'setlocal nobuflisted',
    'setlocal noswapfile',
    'setlocal nowrap',
    'setlocal nonumber',
    'setlocal norelativenumber',
    'setlocal signcolumn=no',
    'setlocal foldcolumn=0',
    'setlocal winfixheight',
    'setlocal cursorline',
    'setlocal filetype=simpletreehelp'
  ]
  for cmd in opts
    call win_execute(s_help_winid, cmd)
  endfor
  call SetupSyntaxHelp()

  call setbufline(s_help_bufnr, 1, lines)
  var bi = getbufinfo(s_help_bufnr)
  if len(bi) > 0
    var lc = get(bi[0], 'linecount', 0)
    if lc > len(lines)
      call deletebufline(s_help_bufnr, len(lines) + 1, lc)
    endif
  endif
  call win_execute(s_help_winid, 'setlocal nomodifiable')
  call win_execute(s_help_winid, 'nnoremap <silent> <buffer> q :close<CR>')
  if WinValid()
    call win_gotoid(s_winid)
  endif
enddef

# ====== Reveal：展开并定位到目标路径 ======
def FocusIfPresent(path: string): bool
  var np = NormPath(path)
  for i in range(len(s_line_index))
    var ep = get(s_line_index[i], 'path', '')
    if ep ==# np || (ep !=# '' && NormPath(ep) ==# np)
      FocusPath(path)
      return true
    endif
  endfor
  return false
enddef

def RevealTimerCb(id: number, session_generation: number, reveal_generation: number)
  if !s_open || session_generation != s_session_generation
      || reveal_generation != s_reveal_generation || s_reveal_target ==# ''
    return
  endif
  if FocusIfPresent(s_reveal_target)
    s_reveal_target = ''
    s_reveal_waiting = {}
    if s_reveal_timer == id
      try
        call timer_stop(id)
      catch
      endtry
      s_reveal_timer = 0
    endif
  endif
enddef

def HasHiddenRelativeComponent(root: string, path: string): bool
  if !IsSubPath(root, path)
    return false
  endif
  var cur = NormPath(path)
  var root_path = NormPath(root)
  var guard = 0
  while !PathEq(cur, root_path) && guard < 500
    var base = fnamemodify(cur, ':t')
    if base =~# '^\.' && base !=# '.' && base !=# '..'
      return true
    endif
    var parent = NormPath(fnamemodify(cur, ':h'))
    if PathEq(parent, cur)
      break
    endif
    cur = parent
    guard += 1
  endwhile
  return false
enddef

def RevealPathIsContained(path: string): bool
  var root_path = NormPath(s_root)
  var candidate = NormPath(path)
  if !IsSubPath(root_path, candidate)
    return false
  endif

  # Checking only resolve(candidate) is insufficient: a lexical ancestor may
  # escape through a symlink and a deeper symlink may re-enter the workspace.
  # Validate every spelling prefix before any reveal/cache state is touched.
  var resolved_root = ResolvedNormPath(root_path)
  var current = candidate
  var guard = 0
  while guard < 500
    if !IsSubPath(resolved_root, ResolvedNormPath(current))
      return false
    endif
    if PathEq(current, root_path)
      return true
    endif
    var parent = NormPath(fnamemodify(current, ':h'))
    if PathEq(parent, current) || !IsSubPath(root_path, parent)
      return false
    endif
    current = parent
    guard += 1
  endwhile
  return false
enddef

def AttachRevealScan(path: string, reveal_generation: number)
  # A streaming scan may already have published a partial cache. Keep its
  # request intact, but attach the current reveal token so its final chunk can
  # complete the selection after the bounded fallback timer has expired.
  if !has_key(s_cache, path) || get(s_loading, path, false)
    s_reveal_waiting[path] = reveal_generation
    ScanDirAsync(path)
  endif
enddef

def RevealPath(path: string)
  if !s_open || path ==# '' || s_root ==# ''
    return
  endif

  var ap = NormPath(path)
  # Fail before generation, expansion, cache or pending-request mutation.
  if !RevealPathIsContained(ap)
    Log('RevealPath: target outside root; skipped: ' .. ap, 'WarningMsg')
    return
  endif
  s_reveal_generation += 1
  var reveal_generation = s_reveal_generation
  s_reveal_target = ap
  s_reveal_waiting = {}
  if s_reveal_timer != 0
    try | call timer_stop(s_reveal_timer) | catch | endtry
    s_reveal_timer = 0
  endif

  # 目标本身或相对根路径中的任一祖先是点目录时，都必须先显示隐藏项。
  if s_hide_dotfiles && HasHiddenRelativeComponent(s_root, ap)
    s_hide_dotfiles = false
    g:simpletree_hide_dotfiles = 0
    echo '[SimpleTree] dotfiles hidden => OFF (auto). Showing hidden to reveal target.'
    Refresh()
    RevealPath(ap)
    return
  endif

  # Symlink leaves are revealed as entries, never traversed. Directories use
  # their own cache so an explicit directory target can also expand normally.
  var cur_dir = getftype(ap) ==# 'dir' ? ap : fnamemodify(ap, ':h')
  var r = s_root
  var guard = 0
  var chain: list<string> = []
  while cur_dir !=# '' && cur_dir !=# r && guard < 500
    chain->insert(cur_dir, 0)
    var nextp = fnamemodify(cur_dir, ':h')
    if nextp ==# cur_dir
      break
    endif
    cur_dir = nextp
    guard += 1
  endwhile

  for d in chain
    var d_state = GetNodeState(d)
    d_state.expanded = true
    AttachRevealScan(d, reveal_generation)
  endfor
  var r_state = GetNodeState(r)
  r_state.expanded = true
  # The root is excluded from chain. Attach the token explicitly when its
  # first scan predates this reveal; otherwise a top-level target could miss
  # the bounded timer and never be selected after a slow root response.
  AttachRevealScan(r, reveal_generation)
  var parent = fnamemodify(ap, ':h')
  var containing_dir = getftype(ap) ==# 'dir' ? ap : parent
  if containing_dir !=# '' && IsSubPath(s_root, containing_dir)
    AttachRevealScan(containing_dir, reveal_generation)
  endif
  Render()

  # 改动点：如果目标行已在当前渲染中出现，立刻定位并结束（不给用户可见跳动）
  if FocusIfPresent(ap)
    s_reveal_target = ''
    s_reveal_waiting = {}
    return
  endif

  # 用少量重试的定时器作为回退（主要靠 ScanDirAsync OnDone 回调触发）
  if exists('*timer_start')
    try
      if s_reveal_timer != 0
        call timer_stop(s_reveal_timer)
      endif
    catch
    endtry
    try
      var session_generation = s_session_generation
      s_reveal_timer = timer_start(150,
        (id) => RevealTimerCb(id, session_generation, reveal_generation), {repeat: 5})
    catch
      FocusPath(ap)
    endtry
  else
    FocusPath(ap)
  endif
enddef
# =============================================================
# 导出 API（供命令调用）
# =============================================================
export def Toggle(root: string = '')
  if WinValid()
    Close()
    return
  endif

  var source_winid = win_getid()
  if &buftype ==# ''
    s_target_winid = source_winid
  endif
  var curf0 = expand('%:p')
  var curf_abs = ''
  if curf0 !=# '' && filereadable(curf0)
    curf_abs = fnamemodify(curf0, ':p')
    s_active_path = curf_abs
  endif

  var rootArg = root
  if rootArg ==# ''
    if (s_open || s_root_locked) && s_root !=# '' && IsDir(s_root)
      # 会话已经在别的 tab 里开着:这里加的是同一棵树的第二个窗口,
      # 不能拿当前文件重新定根,否则会把另一个 tab 的视图也换掉。
      rootArg = s_root
    else
      if curf_abs ==# ''
        rootArg = getcwd()
      else
        rootArg = fnamemodify(curf_abs, ':h')
      endif
    endif
  endif

  s_root = CanonDir(rootArg)
  if !IsDir(s_root)
    echohl ErrorMsg
    echom '[SimpleTree] invalid root: ' .. s_root
    echohl None
    return
  endif

  # 会话代号只在真正新开一个会话时前进。给已有会话加第二个 tab 窗口时
  # 递增它会让所有在途扫描的回调静默作废，而 s_pending 还留着它们的 id。
  if !s_open
    s_session_generation += 1
    s_open = true
  endif
  SeedModifiedPaths()
  EnsureWindowAndBuffer()
  if !BEnsureBackend()
    echohl ErrorMsg
    echom '[SimpleTree] backend not available'
    echohl None
    return
  endif

  var st = GetNodeState(s_root)
  st.expanded = true
  WatchExpandedDirs()
  GitStatusRefresh()
  Emit('Open', {root: s_root})

  # 改动点：如果有当前文件，优先进行 Reveal，避免初始 Render 的闪烁
  if curf_abs !=# '' && filereadable(curf_abs) && IsSubPath(s_root, curf_abs)
    RevealPath(curf_abs)
  else
    # 无当前文件时再正常扫描并渲染
    ScanDirAsync(s_root)
    Render()
  endif
enddef

export def Refresh()
  # 保存当前光标位置
  var current_node = CursorNode()
  var current_path = get(current_node, 'path', '')

  PruneMarks()

  for [p, id] in items(s_pending)
    try
      BCancel(id)
    catch
    endtry
  endfor
  s_pending = {}
  s_loading = {}
  s_cache = {}
  s_cache_has_metadata = {}
  s_loading_has_metadata = {}
  s_scan_errors = {}
  # 清空修改时间缓存，强制重新检测
  s_dir_mtimes = {}
  if s_root !=# ''
    ScanDirAsync(s_root)
  endif
  Render()

  # 异步扫描期间目标行暂时不存在，用 Reveal 在扫描完成后恢复。
  if current_path !=# ''
    RevealPath(current_path)
  endif
enddef

# =============================================================
# 自动刷新相关
# =============================================================
# 上次刷新时间戳（避免过于频繁的刷新）
var s_last_refresh_time: float = 0.0
# 最小刷新间隔（毫秒）- 避免短时间内多次刷新
const MIN_REFRESH_INTERVAL_MS: float = 1000.0
# 目录修改时间缓存（用于检测文件变化）
var s_dir_mtimes: dict<number> = {}

def ShouldAutoRefresh(): bool
  # 检查是否应该进行自动刷新
  if !WinValid() || s_root ==# ''
    return false
  endif

  # 检查时间间隔
  var now = reltime()->reltimefloat() * 1000.0
  if (now - s_last_refresh_time) < MIN_REFRESH_INTERVAL_MS
    return false
  endif

  return true
enddef

# 获取目录的修改时间
def GetDirMtime(dir_path: string): number
  try
    return getftime(dir_path)
  catch
    return -1
  endtry
enddef

# 检测展开的目录是否有变化
def DetectChangesInExpandedDirs(): list<string>
  var changed: list<string> = []

  # 检查根目录
  if s_root !=# '' && isdirectory(s_root)
    var mtime = GetDirMtime(s_root)
    var cached_mtime = get(s_dir_mtimes, s_root, -1)
    if mtime != cached_mtime && mtime != -1
      changed->add(s_root)
    endif
  endif

  # 检查所有展开的目录
  for [path, state] in items(s_state)
    if get(state, 'expanded', false) && isdirectory(path)
      var mtime = GetDirMtime(path)
      var cached_mtime = get(s_dir_mtimes, path, -1)
      if mtime != cached_mtime && mtime != -1
        changed->add(path)
      endif
    endif
  endfor

  return changed
enddef

# 更新目录修改时间缓存
def UpdateDirMtimes(dirs: list<string> = [])
  if len(dirs) == 0
    # 更新所有展开的目录
    if s_root !=# '' && isdirectory(s_root)
      s_dir_mtimes[s_root] = GetDirMtime(s_root)
    endif
    for [path, state] in items(s_state)
      if get(state, 'expanded', false) && isdirectory(path)
        s_dir_mtimes[path] = GetDirMtime(path)
      endif
    endfor
  else
    # 只更新指定的目录
    for path in dirs
      if isdirectory(path)
        s_dir_mtimes[path] = GetDirMtime(path)
      endif
    endfor
  endif
enddef

# 智能刷新：只在有变化时刷新，并保持光标位置
def SmartRefresh()
  if !WinValid() || s_root ==# ''
    return
  endif
  # mtime 轮询检测变化，交给与 fs_event 相同的定点刷新路径。
  RefreshDirs(DetectChangesInExpandedDirs())
enddef

def DoAutoRefresh()
  # 执行自动刷新并更新时间戳
  if ShouldAutoRefresh()
    s_last_refresh_time = reltime()->reltimefloat() * 1000.0
    SmartRefresh()
  endif
enddef

export def AutoRefreshOnFocus()
  # 当 Vim 获得焦点时自动刷新
  # 这通常意味着用户从其他应用程序切换回来，可能有外部文件变化
  DoAutoRefresh()
enddef

export def AutoRefreshOnIdle()
  # 当光标停止移动一段时间后刷新
  # 仅当 simpletree 窗口可见时才刷新
  if !WinValid()
    return
  endif

  # daemon watch 生效时事件已经推送变更；空闲轮询只在无 watch 时兜底。
  # FocusGained 路径仍保留轮询，覆盖睡眠或网络盘丢事件的场景。
  if WatcherEnabled() && !empty(s_watched) && empty(s_watch_failed)
    return
  endif

  # 使用更长的间隔来避免在编辑时频繁刷新
  var now = reltime()->reltimefloat() * 1000.0
  if (now - s_last_refresh_time) < 3000
    return
  endif

  DoAutoRefresh()
enddef

# 只关掉当前 tabpage 的那个窗口;别的 tab 还开着时会话继续。从一个没有树的
# tab 调用 :SimpleTreeClose 仍然是"全部关掉",保持命令原来的语义。
# 最后一个窗口关闭时 bufhidden=wipe 会触发 OnBufWipe(),会话在那里结束。
export def Close()
  var here = TreeWin()
  for winid in (here != 0 ? [here] : TreeWindows())
    try
      call win_execute(winid, 'close')
    catch
    endtry
  endfor
  PruneTabs()
  if empty(s_tabs)
    EndFrontendSession()
    s_bufnr = -1
  endif
  s_winid = 0
enddef

export def Stop()
  BStop()
enddef

export def DebugStatus()
  echo '[SimpleTree] status:'
  echo '  win_valid: ' .. (WinValid() ? 'yes' : 'no')
  echo '  buf_valid: ' .. (BufValid() ? 'yes' : 'no')
  echo '  root: ' .. s_root
  echo '  root_locked: ' .. (s_root_locked ? 'yes' : 'no')
  echo '  active_path: ' .. s_active_path
  var active_line = 0
  if s_active_path !=# ''
    for i in range(len(s_line_index))
      if PathEq(get(s_line_index[i], 'path', ''), s_active_path)
        active_line = i + 1
        break
      endif
    endfor
  endif
  echo '  active_line: ' .. active_line
  echo '  target_winid: ' .. s_target_winid
  echo '  backend_running: ' .. (BIsRunning() ? 'yes' : 'no')
  echo '  pending: ' .. string(items(s_pending))
  echo '  loading: ' .. string(keys(s_loading))
  echo '  scan_errors: ' .. string(s_scan_errors)
  echo '  cache_keys: ' .. string(keys(s_cache))
  var render_stats = RenderStatsSnapshot()
  echo printf('  render: count=%d last=%.2fms max=%.2fms avg=%.2fms visible=%d changed=%d',
    render_stats.renders, render_stats.last_ms, render_stats.max_ms,
    render_stats.avg_ms, render_stats.visible_lines, render_stats.last_changed_lines)
  echo printf('  subtree_cache: entries=%d hit=%d miss=%d hit-rate=%.1f%% invalidations=%d',
    render_stats.cache_entries, render_stats.cache_hits, render_stats.cache_misses,
    render_stats.cache_hit_percent, render_stats.invalidations)
  Log('DebugStatus logged', 'MoreMsg')
enddef


export def Stats(reset: bool = false)
  if reset
    ResetRenderStats()
    echom '[SimpleTree] render statistics reset'
    return
  endif
  var stats = RenderStatsSnapshot()
  echohl Title
  echom '[SimpleTree] render statistics'
  echohl None
  echom printf('  renders=%d last=%.2fms max=%.2fms avg=%.2fms visible=%d',
    stats.renders, stats.last_ms, stats.max_ms, stats.avg_ms, stats.visible_lines)
  echom printf('  buffer changed=%d last / %d total; successful API writes=%d',
    stats.last_changed_lines, stats.total_changed_lines, stats.buffer_writes)
  echom printf('  subtree cache entries=%d hit=%d miss=%d hit-rate=%.1f%%',
    stats.cache_entries, stats.cache_hits, stats.cache_misses, stats.cache_hit_percent)
  echom printf('  epoch=%d invalidations=%d discarded-subtrees=%d',
    stats.epoch, stats.invalidations, stats.invalidated_subtrees)
enddef


def HealthItem(ok: bool, label: string, detail: string = '')
  echohl ok ? 'MoreMsg' : 'ErrorMsg'
  echom printf('  %s %s%s', ok ? '[ok]' : '[!!]', label,
    detail ==# '' ? '' : ': ' .. detail)
  echohl None
enddef

export def Restart()
  SetupCore()
  s_bcbs = {}
  ResetBackendSessionState()
  if simpletree#core#Restart()
    echom '[SimpleTree] backend restarted'
  endif
enddef

export def ShowLog()
  simpletree#core#ShowLog()
enddef

export def Health()
  echohl Title
  echom '[SimpleTree] health check'
  echohl None

  var vim_ok = v:version >= 900
  var float_ok = has('float')
  var async_ok = has('job') && has('channel')
    && exists('*job_start') && exists('*ch_sendraw') && exists('*json_decode')
  var backend = BFindBackend()
  var backend_ok = backend !=# '' && executable(backend)
  HealthItem(vim_ok, 'Vim 9+', printf('v%d.%02d', v:version / 100, v:version % 100))
  HealthItem(async_ok, 'async job/channel/json support')
  HealthItem(float_ok, 'floating-point support')
  HealthItem(backend_ok, 'simpletree-daemon', backend_ok ? backend : 'run ./install.sh or set g:simpletree_daemon_path')
  HealthItem(g:simpletree_page >= 1 && g:simpletree_page <= 1000,
    'page size', string(g:simpletree_page))
  HealthItem(g:simpletree_width >= 10 && g:simpletree_width <= 500,
    'tree width', string(g:simpletree_width))
  var configured_sort = get(g:, 'simpletree_sort', 'name')
  HealthItem(type(configured_sort) == v:t_string
      && index(SORT_MODES, tolower(trim(configured_sort))) >= 0,
    'sort mode', string(configured_sort))

  var trash = TrashCommand('/tmp/simpletree-health-check')
  var trash_detail = !get(g:, 'simpletree_use_trash', 1)
    ? 'disabled'
    : (len(trash) > 0 ? trash[0] : 'no provider; deletes require permanent-delete confirmation')
  echom '  [--] trash: ' .. trash_detail

  var clipboard = !get(g:, 'simpletree_use_system_clipboard', 1) ? 'disabled' : ''
  if clipboard ==# '' && has('clipboard')
    clipboard = 'Vim + register'
  endif
  if clipboard ==# ''
    for command in ClipboardProviders()
      if executable(command[0])
        clipboard = command[0]
        break
      endif
    endfor
  endif
  echom '  [--] system clipboard: ' .. (clipboard ==# '' ? 'no provider; unnamed register still works' : clipboard)

  var caps_detail = 'not connected yet; open the tree first'
  if len(s_backend_caps) > 0
    caps_detail = 'protocol v' .. s_backend_protocol .. ': ' .. join(sort(keys(s_backend_caps)), ', ')
  endif
  echom '  [--] backend capabilities: ' .. caps_detail
  for line in simpletree#core#HealthLines()
    echom '  ' .. line
  endfor
  echom '  [--] git status: ' .. (!get(g:, 'simpletree_git_status', 1)
    ? 'disabled'
    : (HasCap('git-status') ? 'active' : 'waiting for backend capability'))
  echom '  [--] fs watch: ' .. (!get(g:, 'simpletree_use_watcher', 1)
    ? 'disabled (mtime polling)'
    : (HasCap('watch') ? ('active, ' .. len(s_watched) .. ' dir(s)') : 'waiting for backend capability (mtime polling)'))

  if vim_ok && async_ok && float_ok && backend_ok
    echohl MoreMsg | echom '[SimpleTree] ready' | echohl None
  else
    echohl ErrorMsg | echom '[SimpleTree] not ready; resolve the [!!] item(s) above' | echohl None
  endif
enddef

# 仅更新缓冲区状态等轻量装饰，不触发目录扫描。
export def UpdateDecorations()
  if !WinValid() || &buftype !=# ''
    return
  endif
  var path = expand('%:p')
  if path ==# ''
    return
  endif
  path = NormPath(path)
  var modified = !!&modified
  if get(s_modified_paths, path, v:false) == modified
    return
  endif
  if modified
    s_modified_paths[path] = true
    BumpRenderEpoch()
  elseif has_key(s_modified_paths, path)
    call remove(s_modified_paths, path)
    BumpRenderEpoch()
    # modified -> saved 意味着磁盘内容变化；无 watch 时也让 git 装饰跟上。
    GitStatusRefresh()
  endif
  ScheduleRender()
enddef

# 打开树时把当前已修改的 buffer 一次性装载进 path 字典，之后全事件驱动。
def SeedModifiedPaths()
  s_modified_paths = {}
  BumpRenderEpoch()
  for info in getbufinfo({bufmodified: 1})
    if get(info, 'name', '') !=# ''
      s_modified_paths[NormPath(info.name)] = true
      BumpRenderEpoch()
    endif
  endfor
enddef

def RevealInputPath(path: string): string
  var candidate = path
  if candidate !=# '' && candidate[0] ==# '~'
    candidate = expand(candidate)
  endif
  var absolute = candidate =~# '^/'
    || ((has('win32') || has('win64') || has('win32unix'))
      && (candidate =~? '^[A-Za-z]:[/\\]' || candidate =~# '^\\\\'))
  # Command-line relative paths deliberately follow the tree workspace, not
  # :pwd/:lcd, so the same command means the same thing from every split.
  return NormPath(absolute ? candidate : PathJoin(s_root, candidate))
enddef

def RevealCompletionLead(arglead: string): string
  # customlist candidates are fnameescape()'d so paths with spaces survive
  # command-line insertion. Undo those escapes before filesystem inspection.
  if has('win32') || has('win64') || has('win32unix')
    return substitute(arglead, '\\ ', ' ', 'g')->substitute('\\', '/', 'g')
  endif
  return substitute(arglead, '\\\(.\)', '\1', 'g')
enddef

export def CompleteReveal(arglead: string, _cmdline: string,
    _cursorpos: number): list<string>
  if !s_open || s_root ==# ''
    return []
  endif

  var lead = RevealCompletionLead(arglead)
  if lead !=# '' && lead[0] ==# '~'
    lead = expand(lead)
  endif
  var absolute = lead =~# '^/'
    || ((has('win32') || has('win64') || has('win32unix'))
      && (lead =~? '^[A-Za-z]:[/\\]' || lead =~# '^\\\\'))

  # Completing the already typed workspace root does not require enumerating
  # its outside parent. All other parents must pass the same ancestor-by-
  # ancestor boundary used by Reveal before readdir() can traverse them.
  var trailing_separator = (has('win32') || has('win64') || has('win32unix'))
    ? lead =~# '[/\\]$'
    : lead =~# '/$'
  if absolute && !trailing_separator && PathEq(lead, s_root)
      && RevealPathIsContained(lead)
      && isdirectory(s_root)
    return [fnameescape(RStripSlash(lead) .. '/')]
  endif

  var slash = strridx(lead, '/')
  var parent_fragment = slash >= 0 ? strpart(lead, 0, slash) : ''
  if absolute && slash == 0
    parent_fragment = '/'
  endif
  if parent_fragment =~? '^[A-Za-z]:$'
    parent_fragment ..= '/'
  endif
  var prefix = strpart(lead, slash + 1)
  var display_prefix = slash >= 0 ? strpart(lead, 0, slash + 1) : ''
  var parent = absolute
    ? NormPath(parent_fragment)
    : NormPath(PathJoin(s_root, parent_fragment))
  if !RevealPathIsContained(parent) || !isdirectory(parent)
    return []
  endif

  var names: list<string>
  try
    names = readdir(parent)
  catch
    return []
  endtry
  names->sort((left, right) => StringCmp(left, right))

  var matches: list<string> = []
  var ignore_case = &fileignorecase
    || has('win32') || has('win64') || has('win32unix')
  var wanted = ignore_case ? tolower(prefix) : prefix
  for name in names
    var comparable = ignore_case ? tolower(name) : name
    if stridx(comparable, wanted) != 0
      continue
    endif
    var candidate = NormPath(PathJoin(parent, name))
    if !RevealPathIsContained(candidate)
      continue
    endif
    var display = display_prefix .. name
    if isdirectory(candidate)
      display ..= '/'
    endif
    matches->add(fnameescape(display))
  endfor
  return matches
enddef

export def OnRevealCommand(path: string = '')
  # <q-args> gives this boundary the exact command text. Decode the single
  # fnameescape() layer emitted by CompleteReveal, then keep OnRevealActive()
  # as the already-decoded programmatic API.
  OnRevealActive(RevealCompletionLead(path))
enddef

export def OnRevealActive(path: string = '')
  if !s_open || s_root ==# '' || !WinValid()
    echo '[SimpleTree] open the tree before revealing a path'
    return
  endif

  var explicit = path !=# ''
  var target = explicit ? RevealInputPath(path) : s_active_path
  if !explicit && target ==# '' && s_target_winid != 0 && win_id2win(s_target_winid) > 0
    var bnr = winbufnr(s_target_winid)
    var name = bufname(bnr)
    if name !=# ''
      target = NormPath(name)
    endif
  endif
  if target ==# '' || !PathExists(target)
    if explicit
      echo '[SimpleTree] reveal target does not exist: ' .. target
    else
      echo '[SimpleTree] no active file to reveal'
    endif
    return
  endif

  # Both the spelling and its resolved filesystem identity must stay below
  # the workspace. An in-root symlink is revealable only when its target is
  # also in-root; an intermediate symlink cannot turn a relative path into an
  # external scan.
  if !RevealPathIsContained(target)
    if explicit
      echo '[SimpleTree] reveal target is outside the workspace root: ' .. target
    else
      echo '[SimpleTree] active file is outside the workspace root'
    endif
    return
  endif
  RevealPath(target)
enddef

export def OnPreview()
  var node = CursorNode()
  if !IsActionableNode(node) || node.is_dir
    return
  endif
  var target_win = ResolveTargetWindow()
  if target_win < 0
    return
  endif
  if target_win > 0
    try
      call win_execute(target_win, 'silent pedit ' .. fnameescape(node.path))
    catch
      return
    endtry
  else
    if !!get(g:, 'simpletree_split_force_right', 1)
      execute 'belowright vsplit'
    else
      execute 'vsplit'
    endif
    execute 'edit ' .. fnameescape(node.path)
    s_target_winid = win_getid()
    if WinValid()
      call win_gotoid(s_winid)
    endif
  endif
  s_active_path = AbsPath(node.path)
  UpdateActiveHighlight()
enddef

export def OnOpenVSplit()
  var node = CursorNode()
  if !IsActionableNode(node) || node.is_dir
    return
  endif
  var target_win = ResolveTargetWindow()
  if target_win < 0
    return
  endif
  if target_win > 0
    call win_gotoid(target_win)
  endif
  if !!get(g:, 'simpletree_split_force_right', 1)
    execute 'belowright vsplit'
  else
    execute 'vsplit'
  endif
  execute 'edit ' .. fnameescape(node.path)
  s_target_winid = win_getid()
  s_active_path = AbsPath(node.path)
  if !get(g:, 'simpletree_keep_focus', 1) && WinValid()
    call win_gotoid(s_winid)
  endif
enddef

export def OnOpenSplit()
  var node = CursorNode()
  if !IsActionableNode(node) || node.is_dir
    return
  endif

  var keep_in_file = !!get(g:, 'simpletree_keep_focus', 1)

  var target_win = ResolveTargetWindow()
  if target_win < 0
    return
  endif

  if target_win != 0
    # 在目标窗口里做水平分屏，不影响树窗口
    call win_gotoid(target_win)
    if !!get(g:, 'simpletree_split_below', 1) || &splitbelow
      execute 'belowright split'
    else
      execute 'split'
    endif
    execute 'edit ' .. fnameescape(node.path)
  else
    # 无候选窗口：在右侧新建一个垂直分屏并直接在其中打开（不拆树窗口）
    if !!get(g:, 'simpletree_split_force_right', 1)
      execute 'belowright vsplit'
    else
      execute 'vsplit'
    endif
    execute 'edit ' .. fnameescape(node.path)
  endif
  s_target_winid = win_getid()
  s_active_path = AbsPath(node.path)

  if !keep_in_file && WinValid()
    call win_gotoid(s_winid)
  endif
enddef

export def GetRoot(): string
  return s_root
enddef

# =============================================================
# Yank / 系统打开 / Tab 打开
# =============================================================
def ClipboardProviders(): list<list<string>>
  if has('mac') || has('macunix')
    return [['pbcopy']]
  endif
  if has('win32') || has('win64')
    return [['clip.exe']]
  endif
  return [
    ['wl-copy'],
    ['xclip', '-selection', 'clipboard'],
    ['xsel', '--clipboard', '--input'],
  ]
enddef

def CopyToSystemClipboard(text: string): bool
  if !get(g:, 'simpletree_use_system_clipboard', 1)
    return false
  endif
  if has('clipboard')
    try
      setreg('+', text)
      return true
    catch
    endtry
  endif
  for command in ClipboardProviders()
    if !executable(command[0])
      continue
    endif
    try
      call system(ShellJoin(command), text)
      if v:shell_error == 0
        return true
      endif
    catch
    endtry
  endfor
  return false
enddef

export def OnYankPath()
  var node = CursorNode()
  if !IsActionableNode(node)
    return
  endif
  var name = fnamemodify(node.path, ':t')
  setreg('"', name)
  call CopyToSystemClipboard(name)
  echo '[SimpleTree] yanked: ' .. name
enddef

export def OnYankAbsPath()
  var node = CursorNode()
  if !IsActionableNode(node)
    return
  endif
  setreg('"', node.path)
  call CopyToSystemClipboard(node.path)
  echo '[SimpleTree] yanked: ' .. node.path
enddef

export def OnSystemOpen()
  var node = CursorNode()
  if !IsActionableNode(node)
    return
  endif
  var command: list<string> = []
  if has('mac') || has('macunix')
    command = ['open', node.path]
  elseif has('unix')
    command = ['xdg-open', node.path]
  elseif has('win32') || has('win64')
    command = ['cmd.exe', '/c', 'start', '', node.path]
  endif
  if len(command) == 0 || !executable(command[0])
    echo '[SimpleTree] system open not supported on this platform'
    return
  endif
  try
    if exists('*job_start')
      call job_start(command, {out_io: 'null', err_io: 'null'})
    else
      call system(ShellJoin(command))
    endif
  catch
    echohl ErrorMsg | echom '[SimpleTree] system open failed: ' .. v:exception | echohl None
    return
  endtry
  echo '[SimpleTree] opened: ' .. fnamemodify(node.path, ':t')
enddef

export def OnOpenTab()
  var node = CursorNode()
  if !IsActionableNode(node) || node.is_dir
    return
  endif
  execute 'tabedit ' .. fnameescape(node.path)
  s_active_path = AbsPath(node.path)
  s_target_winid = win_getid()
enddef

# =============================================================
# 自动关闭（树为最后一个窗口时自动退出）
# =============================================================
export def OnAutoClose()
  # 延迟到下一帧检测，避免在 WinClosed 期间窗口状态不稳定
  if exists('*timer_start')
    timer_start(0, (_) => {
      if winnr('$') == 1 && &filetype ==# 'simpletree'
        quit
      endif
    })
  endif
enddef

# 状态栏
export def StatusLine(): string
  if s_root ==# ''
    return ' SimpleTree'
  endif
  var display = s_root
  var home = expand('~')
  if home !=# '' && stridx(display, home) == 0
    display = '~' .. display[len(home) :]
  endif
  var flags: list<string> = []
  if s_root_locked
    flags->add('locked')
  endif
  if !s_git_ignore
    flags->add('gitignore:off')
  endif
  if !s_hide_dotfiles
    flags->add('hidden:on')
  endif
  if FilterActive()
    flags->add('filter:' .. s_filter_query)
  endif
  if !empty(s_marked)
    flags->add('marked:' .. len(s_marked))
  endif
  var sort_mode = SortMode()
  if sort_mode !=# 'name' || get(g:, 'simpletree_sort_reverse', 0)
    var reversed = !!get(g:, 'simpletree_sort_reverse', 0)
    var descending_by_default = sort_mode ==# 'mtime' || sort_mode ==# 'size'
    var direction = (descending_by_default != reversed) ? '↓' : '↑'
    flags->add('sort:' .. sort_mode .. direction)
  endif
  return ' EXPLORER  ' .. display .. (len(flags) > 0 ? ('  [' .. join(flags, ',') .. ']') : '')
enddef

# =============================================================
# 深度搜索（daemon 下沉；结果进 quickfix）
# =============================================================
export def Search(query: string, mode: string = 'substring')
  if query ==# ''
    echo '[SimpleTree] usage: :SimpleTreeSearch <query>'
    return
  endif
  if s_root ==# ''
    echo '[SimpleTree] open the tree first to set a root'
    return
  endif
  if !BEnsureBackend()
    return
  endif
  if !HasCap('search')
    echo '[SimpleTree] backend does not support search; rebuild with install.sh'
    return
  endif
  var results: list<dict<any>> = []
  var q = query
  var id = BNextId()
  s_bcbs[id] = {
    OnChunk: (entries) => {
      for e in entries
        results->add({filename: e.path, lnum: 1, text: (e.is_dir ? '[dir] ' : '') .. e.name})
      endfor
    },
    OnDone: () => {
      if len(results) == 0
        echo '[SimpleTree] no matches for: ' .. q
        return
      endif
      call setqflist([], ' ', {title: 'SimpleTree search: ' .. q, items: results})
      execute 'copen'
    },
    OnError: (msg) => {
      echohl WarningMsg
      echom '[SimpleTree] search failed: ' .. msg
      echohl None
    },
  }
  if !BSend({type: 'search', id: id, root: s_root, query: query, mode: mode, show_hidden: !s_hide_dotfiles, git_ignore: s_git_ignore})
    if has_key(s_bcbs, id)
      call remove(s_bcbs, id)
    endif
    echo '[SimpleTree] failed to send search request'
  endif
enddef

# =============================================================
# 测试钩子（headless 测试注入协议事件用；运行时不应调用）
# =============================================================
export def TestSetCaps(caps: list<string>)
  ApplyCapabilities(caps, 2)
enddef

# 测试钩子：关掉子树渲染缓存以取得参照渲染。tests/vim_render_cache.vim 用它
# 比对 "走缓存" 与 "重算" 的结果是否一致。
export def TestSetRenderCache(enabled: bool)
  s_render_cache_off = !enabled
  BumpRenderEpoch()
  s_render_cfg_sig = ''
enddef

export def TestSetFilter(q: string)
  s_filter_query = q
  s_filter_memo = {}
  BumpRenderEpoch()
  Emit('FilterChanged', {query: q})
  Render()
enddef

export def TestGetState(): dict<any>
  var metadata_cache_count = 0
  for path in keys(s_cache)
    if get(s_cache_has_metadata, path, false)
      metadata_cache_count += 1
    endif
  endfor
  var metadata_loading_count = 0
  for path in keys(s_loading)
    if get(s_loading_has_metadata, path, false)
      metadata_loading_count += 1
    endif
  endfor
  return {
    caps: keys(s_backend_caps),
    watched: keys(s_watched),
    git_status_count: len(s_git_status),
    filter: s_filter_query,
    path_lines: len(s_path_lines),
    sort: SortMode(),
    sort_reverse: !!get(g:, 'simpletree_sort_reverse', 0),
    cache_count: len(s_cache),
    metadata_cache_count: metadata_cache_count,
    loading_count: len(s_loading),
    metadata_loading_count: metadata_loading_count,
    render_stats: RenderStatsSnapshot(),
  }
enddef
