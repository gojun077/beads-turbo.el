# Makefile
#
# Created on: Mon 21 Apr 2026
#
# Makefile for 'beads.el' Emacs client for beads issue tracker

# --- Project-specific variables ---
DOLT_REMOTE := gojun077/beads_bdel
DOLT_DB     := beads_bdel
DOLT_DIR    := .beads/dolt
DOLT_PORT   := 3310

# Derive the main repo root from git's common dir (works in worktrees too)
MAIN_REPO   := $(shell git rev-parse --git-common-dir | sed 's|/\.git$$||')
IS_WORKTREE := $(shell [ "$$(git rev-parse --git-common-dir)" = ".git" ] && echo no || echo yes)

.PHONY: setup

setup:
	@echo "==> Checking prerequisites..."
	@command -v dolt  >/dev/null 2>&1 || { echo "ERROR: dolt not found. Install from https://docs.dolthub.com/introduction/installation"; exit 1; }
	@command -v bd    >/dev/null 2>&1 || { echo "ERROR: bd (beads) not found."; exit 1; }
	@command -v git   >/dev/null 2>&1 || { echo "ERROR: git not found."; exit 1; }
	@echo "==> Initializing beads (if not already initialized)..."
	@if [ ! -d ".beads" ]; then \
		bd init --prefix $(DOLT_DB) --server --server-port $(DOLT_PORT) --non-interactive; \
	else \
		echo "    .beads/ already exists, skipping bd init."; \
	fi
	@if grep -q '"dolt_mode": "embedded"' .beads/metadata.json 2>/dev/null; then \
		sed -i '' 's/"dolt_mode": "embedded"/"dolt_mode": "server"/' .beads/metadata.json; \
		echo "    Switched dolt_mode from embedded to server in metadata.json"; \
	fi
ifeq ($(IS_WORKTREE),yes)
	@echo "==> Worktree detected. Connecting to shared dolt server in main repo..."
	@echo "    Main repo: $(MAIN_REPO)"
	bd dolt set port $(DOLT_PORT)
	bd dolt set data-dir $(MAIN_REPO)/$(DOLT_DIR)
	@echo "==> Testing connection to shared dolt server..."
	@bd dolt test || { echo "ERROR: Cannot reach shared dolt server. Run 'make setup' in the main repo first."; exit 1; }
else
	@echo "==> Main repo detected. Initializing dolt server root in $(DOLT_DIR)..."
	@mkdir -p $(DOLT_DIR)
	@if [ ! -d "$(DOLT_DIR)/.dolt" ]; then \
		cd $(DOLT_DIR) && dolt init --name "Peter Jun Koh" --email "gopeterjun@naver.com"; \
	else \
		echo "    $(DOLT_DIR)/.dolt already exists, skipping init."; \
	fi
	@echo "==> Initializing database repo in $(DOLT_DIR)/$(DOLT_DB)..."
	@mkdir -p $(DOLT_DIR)/$(DOLT_DB)
	@if [ ! -d "$(DOLT_DIR)/$(DOLT_DB)/.dolt" ]; then \
		cd $(DOLT_DIR)/$(DOLT_DB) && dolt init --name "Peter Jun Koh" --email "gopeterjun@naver.com"; \
	else \
		echo "    $(DOLT_DIR)/$(DOLT_DB)/.dolt already exists, skipping init."; \
	fi
	@echo "==> Configuring dolt remote on database repo..."
	@cd $(DOLT_DIR)/$(DOLT_DB) && \
		if ! dolt remote -v 2>/dev/null | grep -q origin; then \
			dolt remote add origin $(DOLT_REMOTE); \
			echo "    Added remote 'origin'."; \
		else \
			echo "    Remote 'origin' already configured."; \
		fi
	@echo "==> Fetching data from dolt remote and resetting to remote/main..."
	@cd $(DOLT_DIR)/$(DOLT_DB) && \
		(dolt fetch origin 2>/dev/null || true) && \
		if dolt branch -a 2>/dev/null | grep -q 'remotes/origin/main'; then \
			dolt reset --hard remotes/origin/main; \
		else \
			echo "    No dolt data on remote yet (first-time setup). Skipping reset."; \
		fi
	@echo "==> Pinning dolt server port to $(DOLT_PORT)..."
	bd dolt set port $(DOLT_PORT) --update-config
	@if ! grep -q 'sync.remote:' .beads/config.yaml 2>/dev/null; then \
		echo 'sync.remote: "$(DOLT_REMOTE)"' >> .beads/config.yaml; \
		echo "    Added sync.remote to .beads/config.yaml"; \
	fi
	@echo "==> Restarting dolt server via bd..."
	@bd dolt stop  2>/dev/null || true
	@bd dolt start
endif
	@echo "==> Running bd doctor --fix..."
	@bd doctor --fix --yes
	@echo "==> Configuring beads role..."
	@bd config set beads.role maintainer
	@echo "==> Verifying setup..."
	@bd ready --json >/dev/null 2>&1 && echo "    bd ready: OK" || echo "    WARNING: bd ready returned no tasks (may be expected)"
	@echo ""
	@echo "Setup complete! You can now use 'bd' commands."
	@echo "Run 'bd ready --json' to see available tasks."
