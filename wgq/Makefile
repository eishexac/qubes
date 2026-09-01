# wgq - build and checks. Run from this directory, or via the repository
# root's fan-out (`make -C .. check`).
#
# `make` produces dist/wgq: a single executable file containing the whole
# tool. It runs on the python3 that qubes-core-agent already requires, so
# there is nothing to install and no toolchain to trust.
#
# The archive is a zip, so the source stays readable after packaging:
#
#     unzip -l dist/wgq            # what is in it
#     unzip -p dist/wgq wgq/fwrules.py    # read any file
#
# That is the point. A compiled binary would make the maintainer a trust
# anchor; this keeps the artifact single-file and the contents auditable
# text. The build is also deterministic (../tools/mkzipapp.py, shared by
# every project here): the same tree always produces the same bytes, so a
# downloaded artifact can be verified against your own `make` instead of
# trusted.

PYTHON  ?= python3
DESTDIR ?=
# Default for ordinary machines. Inside a Qubes TEMPLATE use PREFIX=/usr
# instead (as the Salt formula does): /usr/local there is per-qube state,
# seeded once on first boot, and files in it never receive updates.
PREFIX  ?= /usr/local

MKZIPAPP := ../tools/mkzipapp.py
SHA256   := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo "shasum -a 256")

DIST    := dist/wgq
SOURCES := $(shell find src -name '*.py')
SHELL_SCRIPTS := \
	template/etc/qubes/qubes-firewall.d/50-wgq \
	template/usr/sbin/wg-tunnel \
	dom0/msg.sh \
	dom0/wgq \
	dom0/wgq-zone \
	dom0/wgq-uninstall \
	test/verify.sh

.PHONY: all build check verify check-salt clean install version

all: build

# One line, nothing else: the collection's release tooling asks every
# project its version this way (tags are <project>-v<this>).
version:
	@$(PYTHON) -c 'import sys; sys.path.insert(0, "src"); import wgq; print(wgq.__version__)'

build: $(DIST)

$(DIST): $(SOURCES) $(MKZIPAPP)
	@mkdir -p dist
	$(PYTHON) $(MKZIPAPP) src $@
	@printf 'built %s (%s)\n' "$@" "$$(du -h $@ | cut -f1)"

# Every branch below must let a real failure through. `cmd || printf skipped`
# reports success when cmd ran and failed, which is the same defect this
# project calls out in verify.sh: a check that cannot fail is worse than none.
check:
	$(PYTHON) -m compileall -q src
	@for f in $(SHELL_SCRIPTS); do \
		sh -n "$$f" || exit 1; \
		printf 'sh -n ok: %s\n' "$$f"; \
	done
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -s sh $(SHELL_SCRIPTS) || exit 1; \
		printf 'shellcheck ok\n'; \
	else \
		printf 'shellcheck NOT INSTALLED - shell went unlinted\n'; \
	fi
	PYTHONPATH=src $(PYTHON) -m wgq --help >/dev/null && printf 'cli ok\n'
	PYTHONPATH=src $(PYTHON) -m unittest discover -s test -p 'test_*.py' -q
	@if $(PYTHON) -c 'import yaml, jinja2' 2>/dev/null; then \
		$(PYTHON) test/saltcheck.py || exit 1; \
	else \
		printf 'saltcheck NOT RUN - needs pyyaml + jinja2\n'; \
	fi

# Prove the built artifact behaves: exit codes propagate through the
# zipapp, no bytecode leaks in, and two builds of the same tree are
# byte-identical (what makes a published checksum checkable).
verify: build
	./$(DIST) --version >/dev/null
	./$(DIST) servers --help >/dev/null
	@tmp=$$(mktemp -d) && \
	if WGQ_STATE_DIR="$$tmp" ./$(DIST) peer list --zone nowhere >/dev/null 2>&1; then \
		rm -rf "$$tmp"; \
		printf 'FAIL: the zipapp swallowed a non-zero exit code\n'; exit 1; \
	fi; rm -rf "$$tmp"
	@if unzip -l $(DIST) | grep -q __pycache__; then \
		printf 'FAIL: __pycache__ inside the artifact\n'; exit 1; \
	fi
	@unzip -p $(DIST) wgq/fwrules.py | head -1 >/dev/null
	@h1=$$($(SHA256) $(DIST) | awk '{print $$1}'); \
	rm -rf dist; $(MAKE) build >/dev/null; \
	h2=$$($(SHA256) $(DIST) | awk '{print $$1}'); \
	if [ "$$h1" != "$$h2" ]; then \
		printf 'FAIL: two builds of the same tree differ: %s vs %s\n' "$$h1" "$$h2"; exit 1; \
	fi; \
	printf 'verify ok; deterministic build %s\n' "$$h1"

check-salt:
	$(PYTHON) test/saltcheck.py

install: build
	install -D -m 0755 $(DIST) $(DESTDIR)$(PREFIX)/bin/wgq

clean:
	rm -rf dist
	find src test -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
