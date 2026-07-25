vim9script
# Protocol v2 features: capability handshake, fs watch, git status, keymap
# overrides, User events, and the loaded-node filter. Requires the built
# daemon like vim_integration.vim.

set nocompatible
var repo = fnamemodify(expand('<sfile>:p:h'), ':h')
var daemon = repo .. '/target/debug/simpletree-daemon'
if !executable(daemon)
  daemon = repo .. '/lib/simpletree-daemon'
endif
if !executable(daemon)
  echoerr 'daemon binary not found; build with cargo build first'
  cquit
endif

g:simpletree_daemon_path = daemon
g:simpletree_use_trash = 0
g:simpletree_use_system_clipboard = 0
g:simpletree_persist_width = 0
g:simpletree_open_on_create = 0
# 覆盖表：X 映射 refresh，禁用 q
g:simpletree_mappings = {'X': 'refresh', 'q': ''}

exe 'set runtimepath^=' .. fnameescape(repo)
runtime plugin/simpletree.vim

# ---------- fixture ----------
var base = tempname()
call mkdir(base .. '/sub', 'p')
call writefile(['x'], base .. '/file-one.txt')
call writefile(['y'], base .. '/sub/nested.txt')

# ---------- User 事件收集 ----------
g:events = []
augroup TestEvents
  autocmd!
  autocmd User SimpleTreeOpen call add(g:events, 'open')
  autocmd User SimpleTreeDirExpanded call add(g:events, 'expand:' .. fnamemodify(g:simpletree_event.path, ':t'))
  autocmd User SimpleTreeFilterChanged call add(g:events, 'filter:' .. g:simpletree_event.query)
augroup END

def TreeWin(): number
  for w in getwininfo()
    if getbufvar(w.bufnr, '&filetype') ==# 'simpletree'
      return w.winid
    endif
  endfor
  return 0
enddef

def TreeLines(): list<string>
  var w = TreeWin()
  if w == 0
    return []
  endif
  return getbufline(winbufnr(w), 1, '$')
enddef

def WaitFor(Cond: func(): bool, ms: number = 4000): bool
  var waited = 0
  while waited < ms
    if Cond()
      return true
    endif
    sleep 50m
    waited += 50
  endwhile
  return Cond()
enddef

# ---------- 打开树 ----------
execute 'SimpleTree ' .. fnameescape(base)
call assert_true(WaitFor(() => index(TreeLines()->mapnew((_, l) => l =~# 'file-one'), true) >= 0 || match(join(TreeLines()), 'file-one') >= 0), 'tree should list fixture files')

# 事件：Open 必须已触发
call assert_true(index(g:events, 'open') >= 0, 'SimpleTreeOpen event should fire; got: ' .. string(g:events))

# ---------- 能力握手 ----------
call assert_true(WaitFor(() => len(simpletree#TestGetState().caps) > 0), 'capabilities should arrive via pong')
var caps = simpletree#TestGetState().caps
call assert_true(index(caps, 'search') >= 0, 'daemon should advertise search; got: ' .. string(caps))
call assert_true(index(caps, 'git-status') >= 0 || index(caps, 'watch') >= 0, 'daemon should advertise v2 capabilities; got: ' .. string(caps))

# ---------- keymap 覆盖 ----------
var tw = TreeWin()
call assert_true(tw != 0, 'tree window should exist')
var mapped = simpletree#EffectiveKeymap()
call assert_equal('refresh', get(mapped, 'X', ''), 'custom mapping should be honored')
call assert_false(has_key(mapped, 'q'), 'disabled mapping should be removed')
call assert_equal('filter', get(mapped, 'F', ''), 'filter default key should exist')
call assert_equal('find', get(mapped, '/', ''), 'find default key should exist')
var mq = ''
call win_execute(tw, 'g:TestMapQ = maparg("q", "n")')
call assert_equal('', get(g:, 'TestMapQ', 'x'), 'q must not be mapped in tree buffer')
call win_execute(tw, 'g:TestMapX = maparg("X", "n")')
call assert_match('OnRefresh', get(g:, 'TestMapX', ''), 'X should be mapped to refresh')

# ---------- fs watch 端到端（能力可用时） ----------
if index(caps, 'watch') >= 0
  call assert_true(WaitFor(() => len(simpletree#TestGetState().watched) > 0), 'expanded root should be watched')
  call writefile(['z'], base .. '/watched-new.txt')
  call assert_true(WaitFor(() => match(join(TreeLines()), 'watched-new') >= 0, 6000), 'external create should appear via fs_event without manual refresh')
endif

# ---------- 过滤 ----------
call simpletree#TestSetFilter('nested')
# 展开 sub 以载入其缓存，随后过滤应保留 sub 祖先与 nested
var joined0 = join(TreeLines())
call assert_true(index(g:events, 'filter:nested') >= 0, 'FilterChanged event should fire')
call simpletree#TestSetFilter('file-one')
call assert_true(WaitFor(() => match(join(TreeLines()), 'file-one') >= 0), 'filter should keep matching entries')
call assert_true(match(join(TreeLines()), 'watched-new') < 0 || index(caps, 'watch') < 0, 'filter should hide non-matching files')
call simpletree#TestSetFilter('')

# ---------- git status（git 可用时） ----------
if executable('git') && index(caps, 'git-status') >= 0
  var git_base = tempname()
  call mkdir(git_base, 'p')
  call system('git -C ' .. shellescape(git_base) .. ' init -q')
  call system('git -C ' .. shellescape(git_base) .. ' -c user.email=t@t -c user.name=t commit -q --allow-empty -m init')
  call writefile(['u'], git_base .. '/untracked.txt')
  SimpleTreeClose
  execute 'SimpleTree ' .. fnameescape(git_base)
  call assert_true(WaitFor(() => match(join(TreeLines()), 'untracked') >= 0), 'git fixture should render')
  call assert_true(WaitFor(() => simpletree#TestGetState().git_status_count > 0, 6000), 'git statuses should arrive')
endif

# ---------- 结果 ----------
if len(v:errors) > 0
  for e in v:errors
    echom 'ERROR: ' .. e
  endfor
  call writefile(v:errors, '/tmp/simpletree-vim-v2-errors')
  cquit
endif
qa!
