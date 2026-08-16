vim9script
# The suite-integration surface SimpleRemote builds on: the External* accessors,
# 'call:' custom actions in g:simpletree_mappings, per-root ExternalSetRoot
# opts, acwrite (remote://) windows as edit targets, and the reveal of
# foreign-scheme buffers.  Everything simpleremote-shaped is stubbed here: the
# plugin must behave the same whether or not SimpleRemote is installed.

set nocompatible
set nomore

var repo = fnamemodify(expand('<sfile>:p:h'), ':h')
var daemon = repo .. '/target/debug/simpletree-daemon'
if !executable(daemon)
  daemon = repo .. '/lib/simpletree-daemon'
endif
if !executable(daemon)
  echoerr 'daemon binary not found; build with cargo build first'
  cquit
endif

var base = tempname()
mkdir(base .. '/folder', 'p')
mkdir(base .. '/other', 'p')
writefile(['top'], base .. '/top.txt')
writefile(['child'], base .. '/folder/child.txt')
writefile(['bee'], base .. '/other/bee.txt')

# opts.git is only observable against a root that really is a repository with
# something to report; without git on $PATH that half of the test is skipped.
var has_git = executable('git') ? true : false
var gitroot = tempname()
if has_git
  mkdir(gitroot, 'p')
  system('git -C ' .. shellescape(gitroot) .. ' init -q')
  system('git -C ' .. shellescape(gitroot)
    .. ' -c user.email=t@t -c user.name=t commit -q --allow-empty -m init')
  writefile(['dirty'], gitroot .. '/dirty.txt')
endif

g:simpletree_daemon_path = daemon
g:simpletree_persist_width = 0
g:simpletree_persist_state = 0
g:simpletree_root_locked = 0
g:simpletree_use_system_clipboard = 0
g:simpletree_git_status = 0
g:simpletree_choose_window = 0
g:simpletree_keep_focus = 0
g:custom_action_calls = []
# A custom action, a custom action pointing at an autoload-style name, and two
# malformed ones that must be dropped without breaking the rest of the table.
g:simpletree_mappings = {
  'gu': 'call:g:TestCustomUpload',
  'gU': 'call:testplugin#Upload',
  'gB': 'call:not a function',
  'gV': 'call:',
  'gq': 'call:UnwatchAllDirs',
}
execute 'set runtimepath^=' .. fnameescape(repo)
g:simpletree_state_file = tempname() .. '/state.json'
runtime plugin/simpletree.vim

def g:TestCustomUpload()
  add(g:custom_action_calls, simpletree#ExternalSelectedPath())
enddef

def TreeWin(): number
  for w in getwininfo()
    if getbufvar(w.bufnr, '&filetype') ==# 'simpletree' && w.tabnr == tabpagenr()
      return w.winid
    endif
  endfor
  return 0
enddef

def Lines(): list<string>
  var w = TreeWin()
  return w == 0 ? [] : getbufline(winbufnr(w), 1, '$')
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

def Vars(): dict<any>
  var script = getscriptinfo({name: 'autoload/simpletree.vim'})[0]
  return getscriptinfo({sid: script.sid})[0].variables
enddef

def LineOfPath(path: string): number
  var idx = Vars().s_line_index
  for i in range(len(idx))
    if get(idx[i], 'path', '') ==# path
      return i + 1
    endif
  endfor
  return 0
enddef

def SelectPath(path: string)
  var w = TreeWin()
  assert_true(w > 0, 'tree window is missing')
  win_gotoid(w)
  var lnum = LineOfPath(path)
  assert_true(lnum > 0, 'node is not in the tree: ' .. path)
  if lnum > 0
    cursor(lnum, 1)
  endif
enddef

def CursorPath(): string
  var w = TreeWin()
  var idx = Vars().s_line_index
  var lnum = getcurpos(w)[1]
  return lnum > 0 && lnum <= len(idx) ? get(idx[lnum - 1], 'path', '') : ''
enddef

# ---------------------------------------------------------------- open tree ---
enew
execute 'SimpleTree ' .. fnameescape(base)
assert_true(WaitFor(() => LineOfPath(base .. '/top.txt') > 0), 'tree should list the fixture')

# ------------------------------------------- 1. selected node / marked paths ---
SelectPath(base .. '/top.txt')
assert_equal(base .. '/top.txt', simpletree#ExternalSelectedPath())
assert_equal({path: base .. '/top.txt', is_dir: false}, simpletree#ExternalSelectedNode())
SelectPath(base .. '/folder')
assert_equal(base .. '/folder', simpletree#ExternalSelectedPath())
assert_equal({path: base .. '/folder', is_dir: true}, simpletree#ExternalSelectedNode())
# The returned dict is a copy: mutating it must not touch the tree's index.
var node = simpletree#ExternalSelectedNode()
node.path = '/mutated'
assert_equal(base .. '/folder', simpletree#ExternalSelectedPath(), 'ExternalSelectedNode leaked the live entry')
assert_equal(base .. '/folder', simpletree#ExternalDropDirectory())

assert_equal([], simpletree#ExternalMarkedPaths())
SelectPath(base .. '/top.txt')
simpletree#OnMarkToggle()
SelectPath(base .. '/folder')
simpletree#OnMarkToggle()
assert_equal([base .. '/folder', base .. '/top.txt'], simpletree#ExternalMarkedPaths(), 'marked paths, sorted')
var marked = simpletree#ExternalMarkedPaths()
marked->add('/mutated')
assert_equal(2, len(simpletree#ExternalMarkedPaths()), 'ExternalMarkedPaths leaked the live list')

# From a tab without a tree window there is no cursor node; marks are global.
tabnew
assert_equal('', simpletree#ExternalSelectedPath())
assert_equal({}, simpletree#ExternalSelectedNode())
assert_equal(2, len(simpletree#ExternalMarkedPaths()))
assert_equal(base, simpletree#ExternalDropDirectory(), 'without a tree window the drop directory is the root')
tabclose
simpletree#OnMarkClear()
assert_equal([], simpletree#ExternalMarkedPaths())

# ------------------------------------------------- 2. call: custom actions ---
var mapped = simpletree#EffectiveKeymap()
assert_equal('call:g:TestCustomUpload', get(mapped, 'gu', ''))
assert_equal('call:testplugin#Upload', get(mapped, 'gU', ''))
assert_false(has_key(mapped, 'gB'), 'malformed call: action must be dropped')
assert_false(has_key(mapped, 'gV'), 'empty call: action must be dropped')
# A bare name has no scope the mapping could reach -- it is neither a global
# nor an autoload function, and it certainly cannot name one of the tree's own
# script-local functions -- so it must be dropped at configuration time rather
# than installed to die with E117 on every keypress.
assert_false(has_key(mapped, 'gq'), 'unscoped call: action must be dropped')
assert_equal('open', get(mapped, 'o', ''), 'built-in actions survive next to custom ones')
var tw = TreeWin()
win_execute(tw, 'g:TestMapGu = maparg("gu", "n")')
assert_match('call g:TestCustomUpload()', get(g:, 'TestMapGu', ''), 'gu must call the custom function')
win_execute(tw, 'g:TestMapGU = maparg("gU", "n")')
assert_match('call testplugin#Upload()', get(g:, 'TestMapGU', ''))
win_execute(tw, 'g:TestMapGB = maparg("gB", "n")')
assert_equal('', get(g:, 'TestMapGB', 'x'), 'malformed action must not be installed')
win_execute(tw, 'g:TestMapGq = maparg("gq", "n")')
assert_equal('', get(g:, 'TestMapGq', 'x'), 'unscoped action must not be installed')
SelectPath(base .. '/folder')
simpletree#OnExpand()
assert_true(WaitFor(() => LineOfPath(base .. '/folder/child.txt') > 0), 'folder should expand')
SelectPath(base .. '/folder/child.txt')
var selected_before = CursorPath()
execute "normal gu"
assert_equal([selected_before], g:custom_action_calls, 'the custom action runs with the tree selection intact')

# The ? help panel lists custom actions after the built-in keys.
simpletree#ShowHelp()
var help_pop = Vars().s_help_popupid
var help_lines: list<string> = []
if help_pop != 0
  help_lines = getbufline(winbufnr(help_pop), 1, '$')
else
  help_lines = getbufline(Vars().s_help_bufnr, 1, '$')
endif
simpletree#ShowHelp()
assert_true(len(help_lines) > 10, 'help panel did not render')
assert_true(match(help_lines, 'gu\s\+.*call g:TestCustomUpload()') >= 0,
  'help must list the custom action: ' .. string(help_lines))
assert_true(match(help_lines, 'gU\s\+.*call testplugin#Upload()') >= 0)
assert_true(match(help_lines, 'gB') < 0, 'malformed actions stay out of the help')

# ------------------------------------------- 3. ExternalSetRoot with opts ---
assert_equal({watch: true, git: true}, simpletree#TestGetState().root_opts)
assert_true(WaitFor(() => len(simpletree#TestGetState().caps) > 0), 'capabilities should arrive')
var caps = simpletree#TestGetState().caps
# The per-root switch is only meaningful against a daemon that can watch.
assert_true(index(caps, 'watch') >= 0, 'daemon should advertise watch; got: ' .. string(caps))
assert_true(WaitFor(() => len(simpletree#TestGetState().watched) > 0), 'the root should be watched by default')

g:root_events = []
augroup TestExternalRoot
  autocmd!
  autocmd User SimpleTreeRootChanged call add(g:root_events, copy(g:simpletree_event))
augroup END

assert_true(simpletree#ExternalSetRoot(base .. '/other', 'simpleremote', {watch: false, git: false}))
assert_equal({watch: false, git: false}, simpletree#TestGetState().root_opts)
assert_equal(1, len(g:root_events))
assert_equal('simpleremote', g:root_events[0].source)
assert_equal(base .. '/other', g:root_events[0].root)
assert_true(WaitFor(() => LineOfPath(base .. '/other/bee.txt') > 0), 'new root should be listed')
assert_equal([], simpletree#TestGetState().watched, 'watch:false must not register a watch for the new root')

# Without a watch the idle path must fall through to mtime polling and pick up
# an external change.  Directory mtimes have one-second resolution.
sleep 1100m
writefile(['late'], base .. '/other/polled.txt')
simpletree#AutoRefreshOnIdle()
assert_true(WaitFor(() => LineOfPath(base .. '/other/polled.txt') > 0),
  'idle polling should list a file created while watching is off')
assert_equal([], simpletree#TestGetState().watched, 'polling refresh must not sneak a watch back in')

# Any other root change resets the per-root opts.
simpletree#OnRootUp()
assert_equal({watch: true, git: true}, simpletree#TestGetState().root_opts, 'U must reset provider opts')
assert_equal(base, simpletree#GetRoot())
assert_true(WaitFor(() => len(simpletree#TestGetState().watched) > 0), 'watching resumes after a normal root change')
# ...and an external root change without opts means defaults, not "keep".
assert_true(simpletree#ExternalSetRoot(base .. '/other', 'simpleremote', {watch: false}))
assert_equal({watch: false, git: true}, simpletree#TestGetState().root_opts)
assert_true(simpletree#ExternalSetRoot(base, 'simpleremote'))
assert_equal({watch: true, git: true}, simpletree#TestGetState().root_opts)
assert_true(WaitFor(() => LineOfPath(base .. '/top.txt') > 0))

# The git half of the same switch.  Everything else in this file runs with
# git status off globally, which would leave the per-root flag dead code: turn
# it on for this section only, against a root that is a real repository.
if has_git
  g:simpletree_git_status = 1
  assert_true(simpletree#ExternalSetRoot(gitroot, 'simpleremote'))
  assert_true(WaitFor(() => LineOfPath(gitroot .. '/dirty.txt') > 0), 'git fixture should be listed')
  assert_equal({watch: true, git: true}, simpletree#TestGetState().root_opts)
  assert_true(WaitFor(() => simpletree#TestGetState().git_status_count > 0),
    'without the opt-out the same root must produce git marks')
  var git_health = substitute(execute('call simpletree#Health()'), '\n', ' || ', 'g')
  assert_true(git_health =~# 'git status: \d\+ entr',
    'health should report a working git query: ' .. git_health)

  # ...and the provider can switch it off for its own root, which is the point
  # on an sshfs mount: git status would walk the network on every refresh.
  assert_true(simpletree#ExternalSetRoot(gitroot, 'simpleremote', {git: false}))
  assert_equal({watch: true, git: false}, simpletree#TestGetState().root_opts)
  assert_true(WaitFor(() => LineOfPath(gitroot .. '/dirty.txt') > 0))
  # The query is debounced by 200ms; give it more than that to prove it never
  # goes out rather than merely has not gone out yet.
  sleep 800m
  assert_equal(0, simpletree#TestGetState().git_status_count,
    'git:false must not issue a git status query for this root')
  git_health = substitute(execute('call simpletree#Health()'), '\n', ' || ', 'g')
  assert_true(git_health =~# 'git status: disabled for this root by its provider',
    'health must name the provider as the reason: ' .. git_health)
  # A refresh of the same root does not sneak the query back in either.
  simpletree#OnRefresh()
  sleep 800m
  assert_equal(0, simpletree#TestGetState().git_status_count,
    'refreshing a git:false root must stay quiet')

  # Any other root change resets it, and the marks come back.
  assert_true(simpletree#ExternalSetRoot(gitroot, 'simpleremote'))
  assert_equal({watch: true, git: true}, simpletree#TestGetState().root_opts)
  assert_true(WaitFor(() => simpletree#TestGetState().git_status_count > 0),
    'the reset must restore git status for the same root')
  g:simpletree_git_status = 0
  assert_true(simpletree#ExternalSetRoot(base, 'simpleremote'))
  assert_true(WaitFor(() => LineOfPath(base .. '/top.txt') > 0))
endif

augroup TestExternalRoot
  autocmd!
augroup END

# --------------------------------------- 4. acwrite windows as edit targets ---
# Only the tree and one acwrite window (a remote:// buffer the way SimpleRemote
# names them) are open: opening a file from the tree must reuse that window
# instead of forcing a new split.
only!
SimpleTreeClose
sleep 100m
enew
execute 'silent file remote:///srv/app/main.py'
setlocal buftype=acwrite
b:vimrc_remote = {path: '/srv/app/main.py', uri: 'remote:///srv/app/main.py', generation: 1}
var remote_win = win_getid()
var remote_buf = bufnr('%')
execute 'SimpleTree ' .. fnameescape(base)
assert_true(WaitFor(() => LineOfPath(base .. '/top.txt') > 0))
assert_equal(remote_win, Vars().s_target_winid, 'toggling from an acwrite window records it as the edit target')
SelectPath(base .. '/top.txt')
simpletree#OnEnter()
sleep 100m
assert_equal(2, winnr('$'), 'the file must open in the acwrite window, not a new split')
assert_equal(base .. '/top.txt', fnamemodify(bufname(winbufnr(remote_win)), ':p'))

# The opt-out restores the historical "normal buffers only" behavior.
win_gotoid(remote_win)
execute 'silent buffer ' .. remote_buf
g:simpletree_target_buftypes = ['']
SelectPath(base .. '/folder')
if LineOfPath(base .. '/folder/child.txt') == 0
  simpletree#OnExpand()
  assert_true(WaitFor(() => LineOfPath(base .. '/folder/child.txt') > 0))
endif
SelectPath(base .. '/folder/child.txt')
simpletree#OnEnter()
sleep 100m
assert_equal(3, winnr('$'), 'with acwrite excluded a new split is forced')
assert_equal(remote_buf, winbufnr(remote_win), 'the acwrite window must be left alone')
unlet g:simpletree_target_buftypes
only!
SimpleTreeClose
sleep 100m

# A remote:// buffer is modified for as long as the edit is unsaved, and with
# 'hidden' off (Vim's default) :edit into that window raises E37.  Before
# acwrite windows were candidates at all such a window simply forced a split;
# now that it is a candidate the reuse must fall back to that split rather than
# throwing out of the mapping and leaving the cursor in the remote buffer.
assert_false(&hidden, 'this case only exists with nohidden')
enew
execute 'silent file remote:///srv/app/dirty.py'
setlocal buftype=acwrite
setline(1, 'unsaved remote edit')
var dirty_win = win_getid()
var dirty_buf = bufnr('%')
assert_true(getbufvar(dirty_buf, '&modified') ? true : false, 'fixture buffer must be modified')
execute 'SimpleTree ' .. fnameescape(base)
assert_true(WaitFor(() => LineOfPath(base .. '/top.txt') > 0))
assert_equal(dirty_win, Vars().s_target_winid)
SelectPath(base .. '/top.txt')
try
  simpletree#OnEnter()
catch
  assert_report('opening next to a modified acwrite buffer threw: ' .. v:exception)
endtry
sleep 100m
assert_equal(3, winnr('$'), 'a target window that cannot be reused must be split')
assert_equal(dirty_buf, winbufnr(dirty_win), 'the unsaved buffer must be left alone')
assert_equal(base .. '/top.txt', Vars().s_active_path, 'the file must still be opened')
assert_notequal(dirty_win, Vars().s_target_winid, 'the new split becomes the edit target')
assert_equal(TreeWin(), win_getid(), 'the cursor must come back to the tree, not stay in the remote buffer')
setbufvar(dirty_buf, '&modified', 0)
only!
SimpleTreeClose
sleep 100m

# ------------------------------------------ 5. reveal of foreign buffers ---
# The listener also records where it ran: providers (SimpleRemote's
# g:SimpleRemoteTreeReveal) decide on the current buffer, so the event has to
# fire in the foreign buffer's own window, not in the tree.
g:foreign_events = []
g:foreign_context = []
def g:RecordForeign()
  add(g:foreign_events, copy(g:simpletree_event))
  add(g:foreign_context, [win_getid(), bufnr('%')])
enddef
augroup TestForeign
  autocmd!
  autocmd User SimpleTreeRevealForeign call g:RecordForeign()
augroup END

execute 'silent buffer ' .. remote_buf
remote_win = win_getid()
execute 'SimpleTree ' .. fnameescape(base)
assert_true(WaitFor(() => LineOfPath(base .. '/top.txt') > 0))
# Pretend the user edited a local file earlier: s_active_path is stale.
SelectPath(base .. '/top.txt')
simpletree#OnEnter()
sleep 100m
win_gotoid(remote_win)
execute 'silent buffer ' .. remote_buf
doautocmd BufEnter
var tree_win = TreeWin()
win_gotoid(tree_win)
simpletree#OnRevealActive()
assert_equal(1, len(g:foreign_events), 'f on a remote:// target must hand over to the provider')
if len(g:foreign_events) == 1
  assert_equal('remote:///srv/app/main.py', g:foreign_events[0].name)
  assert_equal('/srv/app/main.py', g:foreign_events[0].path)
  assert_equal(remote_buf, g:foreign_events[0].bufnr)
  assert_equal(remote_win, g:foreign_events[0].winid)
  assert_equal([remote_win, remote_buf], g:foreign_context[0],
    'the event must fire in the foreign buffer window')
endif
assert_equal(tree_win, win_getid(),
  'a listener that opens nothing leaves the cursor where f was pressed')

# From the remote buffer's own window (no argument) the current buffer wins.
win_gotoid(remote_win)
SimpleTreeReveal
assert_equal(2, len(g:foreign_events))
if len(g:foreign_events) == 2
  assert_equal(remote_buf, g:foreign_events[1].bufnr)
  assert_equal([remote_win, remote_buf], g:foreign_context[1])
endif

# An explicit foreign path is neither joined onto the root nor reported as
# missing; the buffer and its window are looked up by name.
win_gotoid(tree_win)
SimpleTreeReveal remote:///srv/app/main.py
assert_equal(3, len(g:foreign_events))
if len(g:foreign_events) == 3
  assert_equal(remote_buf, g:foreign_events[2].bufnr)
  assert_equal(remote_win, g:foreign_events[2].winid)
  assert_equal([remote_win, remote_buf], g:foreign_context[2])
endif
# A name no buffer carries has neither: the payload is all the provider gets.
SimpleTreeReveal remote:///srv/app/nowhere.py
assert_equal(4, len(g:foreign_events))
if len(g:foreign_events) == 4
  assert_equal(0, g:foreign_events[3].bufnr)
  assert_equal(0, g:foreign_events[3].winid)
  assert_equal('/srv/app/nowhere.py', g:foreign_events[3].path)
  assert_equal(tree_win, g:foreign_context[3][0], 'no window to switch to')
endif

# A provider shaped like SimpleRemote's g:SimpleRemoteTreeReveal(), which
# decides from the current buffer and its b:vimrc_remote rather than from the
# payload, must still receive the remote path when f was pressed in the tree.
g:provider_paths = []
def g:CurrentBufferProvider()
  if bufname() !~# '^remote://'
    if exists(':SimpleTreeReveal') == 2
      execute 'SimpleTreeReveal'
    endif
    return
  endif
  add(g:provider_paths, get(get(b:, 'vimrc_remote', {}), 'path', ''))
enddef
augroup TestForeign
  autocmd!
  autocmd User SimpleTreeRevealForeign call g:CurrentBufferProvider()
augroup END
win_gotoid(tree_win)
simpletree#OnRevealActive()
assert_equal(['/srv/app/main.py'], g:provider_paths,
  'a current-buffer provider must see the foreign buffer, not the tree')

# A provider that opens its own window keeps it: the cursor is not dragged
# back to the tree.
g:foreign_events = []
g:foreign_context = []
augroup TestForeign
  autocmd!
  autocmd User SimpleTreeRevealForeign call g:RecordForeign() | topleft new
augroup END
win_gotoid(tree_win)
simpletree#OnRevealActive()
assert_equal(1, len(g:foreign_events))
assert_notequal(tree_win, win_getid(), 'the provider window must keep the focus')
assert_notequal(remote_win, win_getid())
quit

# A listener that bounces back into :SimpleTreeReveal (a provider deciding on
# the current buffer, which after its own window switch is no longer the
# remote one) must not recurse.  This is also what SimpleRemote does while it
# is disconnected, so the bounce must not turn f into a silent no-op either:
# the nested call falls back to the last local file the tree opened.
g:foreign_events = []
g:foreign_context = []
augroup TestForeign
  autocmd!
  autocmd User SimpleTreeRevealForeign call g:RecordForeign() | SimpleTreeReveal
augroup END
SelectPath(base .. '/folder')
assert_notequal(base .. '/top.txt', CursorPath())
win_gotoid(tree_win)
try
  simpletree#OnRevealActive()
catch
  assert_report('re-entrant reveal raised: ' .. v:exception)
endtry
assert_equal(1, len(g:foreign_events), 'a re-entrant provider must see exactly one event')
assert_equal(base .. '/top.txt', CursorPath(),
  'a provider that cannot act must leave f with the active file, not with nothing')

# Projected mode: g:SimpleRemoteLocalPath maps the remote path to a readable
# local file, which is revealed as usual and never reaches the provider.
g:foreign_events = []
g:foreign_context = []
augroup TestForeign
  autocmd!
  autocmd User SimpleTreeRevealForeign call g:RecordForeign()
augroup END
def g:SimpleRemoteLocalPath(remote: string): string
  return remote =~# '^/srv/app/' ? base .. strpart(remote, len('/srv/app')) : ''
enddef
win_gotoid(remote_win)
execute 'silent file remote:///srv/app/folder/child.txt'
win_gotoid(TreeWin())
simpletree#OnRevealActive()
assert_true(WaitFor(() => LineOfPath(base .. '/folder/child.txt') > 0), 'projected reveal must expand to the mapped file')
assert_equal(base .. '/folder/child.txt', CursorPath(), 'projected reveal must select the mapped file')
assert_equal([], g:foreign_events, 'a mapped foreign buffer is a local reveal, not a provider event')
# The mapping only counts when the local file is really there.
win_gotoid(remote_win)
execute 'silent file remote:///srv/app/folder/missing.txt'
win_gotoid(TreeWin())
simpletree#OnRevealActive()
assert_equal(1, len(g:foreign_events), 'an unreadable mapping falls back to the provider')

# d (root_current) follows the same mapping: the acwrite window's remote name
# resolves to a local file whose directory becomes the root.
win_gotoid(remote_win)
execute 'silent file remote:///srv/app/folder/child.txt'
win_gotoid(TreeWin())
simpletree#OnRootCurrent()
assert_equal(base .. '/folder', simpletree#GetRoot(), 'd must use the mapped file directory as root')

augroup TestForeign
  autocmd!
augroup END
delfunction g:SimpleRemoteLocalPath

# ----------------- 6. a foreign buffer nobody claims is not a dead end ---
# On a plain local setup nothing listens for SimpleTreeRevealForeign and there
# is no g:SimpleRemoteLocalPath -- yet acwrite buffers exist anyway (fugitive's
# index buffers are the common case).  Handing such a buffer to a provider that
# is not there must not cost the user the reveal: f falls back to the active
# file, which is exactly what it did before foreign names were understood.
assert_false(exists('#User#SimpleTreeRevealForeign'), 'no provider may be registered here')
assert_false(exists('*g:SimpleRemoteLocalPath'), 'no projection may be available here')
assert_true(simpletree#ExternalSetRoot(base, 'test'))
assert_true(WaitFor(() => LineOfPath(base .. '/top.txt') > 0))
only!
SimpleTreeClose
sleep 100m
enew
execute 'SimpleTree ' .. fnameescape(base)
assert_true(WaitFor(() => LineOfPath(base .. '/top.txt') > 0))
SelectPath(base .. '/top.txt')
simpletree#OnEnter()
sleep 100m
assert_equal(base .. '/top.txt', Vars().s_active_path)

# A fugitive-style acwrite window becomes the most recently used editor window.
wincmd p
new
execute 'silent file fugitive:///repo/.git//0/some/file.txt'
setlocal buftype=acwrite
doautocmd BufEnter
assert_equal(win_getid(), Vars().s_target_winid, 'the acwrite window is the edit target')

SelectPath(base .. '/other')
assert_notequal(base .. '/top.txt', CursorPath())
win_gotoid(TreeWin())
var unclaimed = execute('call simpletree#OnRevealActive()')
assert_equal(base .. '/top.txt', CursorPath(),
  'an unclaimed foreign buffer must not swallow f')
assert_false(unclaimed =~# 'no local file to reveal',
  'the fallback must be quiet, not an excuse: ' .. unclaimed)

# When there is no local file behind the name either, say so instead of
# failing silently.
var missing = execute('call simpletree#OnRevealActive("fugitive:///repo/.git//0/nowhere.txt")')
assert_true(missing =~# 'no local file to reveal for fugitive:///repo/.git//0/nowhere.txt',
  'an unclaimed explicit foreign path must be reported: ' .. missing)

SimpleTreeClose
delete(base, 'rf')
if has_git
  delete(gitroot, 'rf')
endif
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
