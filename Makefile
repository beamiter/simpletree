.PHONY: check shell fmt clippy test vim-test vim-core defcompile core-verify

check: core-verify shell fmt clippy test defcompile vim-core vim-test

# The installer is the only thing a user runs before any of the above can exist,
# so a syntax error in it is the one failure nothing else catches.  CI used to
# check this in a step of its own; it lives here so `make check` remains the
# whole gate and CI needs exactly one line.
shell:
	bash -n install.sh
	bash -n install-common.sh

fmt:
	cargo fmt --all -- --check

clippy:
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --locked

vim-test:
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_integration.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_v2_features.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_runtime_controls.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_render_cache.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_bookmarks.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_sorting.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_reveal.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_tabpages.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_marks.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_health.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_search.vim
	vim -Nu NONE -n -i NONE -es -S tests/vim_fsops.vim

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpletree/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
core-verify:
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
