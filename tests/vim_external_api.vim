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
assert_equal('open', get(mapped, 'o', ''), 'built-in actions survive next to custom ones')
var tw = TreeWin()
win_execute(tw, 'g:TestMapGu = maparg("gu", "n")')
assert_match('call g:TestCustomUpload()', get(g:, 'TestMapGu', ''), 'gu must call the custom function')
win_execute(tw, 'g:TestMapGU = maparg("gU", "n")')
assert_match('call testplugin#Upload()', get(g:, 'TestMapGU', ''))
win_execute(tw, 'g:TestMapGB = maparg("gB", "n")')
assert_equal('', get(g:, 'TestMapGB', 'x'), 'malformed action must not be installed')
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
# remote one) must not recurse.
g:foreign_events = []
g:foreign_context = []
augroup TestForeign
  autocmd!
  autocmd User SimpleTreeRevealForeign call g:RecordForeign() | SimpleTreeReveal
augroup END
win_gotoid(tree_win)
try
  simpletree#OnRevealActive()
catch
  assert_report('re-entrant reveal raised: ' .. v:exception)
endtry
assert_equal(1, len(g:foreign_events), 'a re-entrant provider must see exactly one event')

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

SimpleTreeClose
delete(base, 'rf')
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit
endif
qall!
