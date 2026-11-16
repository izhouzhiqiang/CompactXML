# BUAA thesis: run make in the same directory as main.tex.
# Requires TeX Live / MacTeX with latexmk and XeLaTeX.
SHELL := /bin/sh
.DEFAULT_GOAL := pdf

# macOS GUI applications may not inherit the TeX Live path.
export PATH := /Library/TeX/texbin:$(PATH)

# Choose an installed UTF-8 locale: macOS may not provide C.UTF-8.
TEX_LOCALE := $(shell locale -a 2>/dev/null | LC_ALL=C awk 'tolower($$0) ~ /utf-?8/ { if (!first) first = $$0; if (tolower($$0) ~ /^en_us\./) preferred = $$0 } END { print preferred ? preferred : (first ? first : "C") }')
export LANG := $(TEX_LOCALE)
export LC_ALL := $(TEX_LOCALE)
export LC_CTYPE := $(TEX_LOCALE)

MAIN ?= main
LATEXMK ?= latexmk
XELATEX ?= xelatex
LATEXMK_FLAGS ?= -norc -xelatex -interaction=nonstopmode -file-line-error -halt-on-error -synctex=1
MSG ?= 更新论文内容及项目文件
export MSG

.PHONY: all pdf rebuild watch open check clean commit help

all: pdf

# latexmk detects dependencies, including chapter files, figures and references.
pdf: check
	"$(LATEXMK)" $(LATEXMK_FLAGS) -e '$$xelatex = q{"$(XELATEX)" %O %S};' "$(MAIN).tex"

# Force all compilation rules to run, without deleting the existing PDF first.
rebuild: check
	"$(LATEXMK)" $(LATEXMK_FLAGS) -g -e '$$xelatex = q{"$(XELATEX)" %O %S};' "$(MAIN).tex"

# Watch for changes; Ctrl+C stops watching. Do not launch a PDF viewer.
watch: check
	"$(LATEXMK)" $(LATEXMK_FLAGS) -pvc -view=none -e '$$xelatex = q{"$(XELATEX)" %O %S};' "$(MAIN).tex"

open: pdf
	@case "$$(uname -s)" in \
		Darwin) open "$(MAIN).pdf" ;; \
		*) if command -v xdg-open >/dev/null 2>&1; then \
			xdg-open "$(MAIN).pdf"; \
		else \
			printf '%s\n' 'No PDF viewer found; open $(MAIN).pdf manually.' >&2; \
			exit 1; \
		fi ;; \
	esac

check:
	@command -v "$(LATEXMK)" >/dev/null 2>&1 || { \
		printf '%s\n' 'latexmk not found. Install TeX Live / MacTeX or set LATEXMK=/path/to/latexmk.' >&2; \
		exit 1; \
	}
	@command -v "$(XELATEX)" >/dev/null 2>&1 || { \
		printf '%s\n' 'xelatex not found. Install TeX Live / MacTeX or set XELATEX=/path/to/xelatex.' >&2; \
		exit 1; \
	}
	@test -f "$(MAIN).tex" || { \
		printf '%s\n' 'Missing $(MAIN).tex. Run make in the thesis project directory.' >&2; \
		exit 1; \
	}

# Remove auxiliary files only. Keep the PDF, source files and template assets.
# Auxiliary files are ignored by Git; PDFs remain tracked. No Git operations here.
clean:
	@command -v "$(LATEXMK)" >/dev/null 2>&1 || { \
		printf '%s\n' 'latexmk not found; no files were removed.' >&2; \
		exit 1; \
	}
	@test -f "$(MAIN).tex" || { \
		printf '%s\n' 'Missing $(MAIN).tex; no files were removed.' >&2; \
		exit 1; \
	}
	"$(LATEXMK)" -norc -c "$(MAIN).tex"

# Stage project changes (respecting .gitignore) and commit locally only.
# Pass the message through the environment, not interpolated shell code.
commit:
	@set -eu; \
	command -v git >/dev/null 2>&1 || { \
		printf '%s\n' 'git not found; no changes were staged.' >&2; exit 1; \
	}; \
	git rev-parse --show-toplevel >/dev/null; \
	test -z "$$(git rev-parse --show-prefix)" || { \
		printf '%s\n' 'Run make commit at the Git repository root.' >&2; exit 1; \
	}; \
	for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do \
		if test -e "$$(git rev-parse --git-path "$$state")"; then \
			printf '%s\n' 'An unfinished Git operation exists; resolve it before committing.' >&2; exit 1; \
		fi; \
	done; \
	test -z "$$(git diff --name-only --diff-filter=U)" || { \
		printf '%s\n' 'Unresolved conflicts exist; no changes were staged.' >&2; exit 1; \
	}; \
	printf '%s' "$$MSG" | grep -q '[^[:space:]]' || { \
		printf '%s\n' 'A non-empty commit message is required: make commit MSG="your message"' >&2; exit 1; \
	}; \
	git add -A -- .; \
	if git diff --cached --quiet; then \
		printf '%s\n' 'No changes to commit.'; \
	else \
		git diff --cached --check || printf '%s\n' 'Warning: whitespace issues found; files are left unchanged.' >&2; \
		git diff --cached --stat; \
		git commit -m "$$MSG"; \
	fi

help:
	@printf '%s\n' \
		'make / make pdf   Build the thesis with XeLaTeX and latexmk.' \
		'make rebuild      Force recompilation without deleting the PDF first.' \
		'make watch        Rebuild when source files change (Ctrl+C to stop).' \
		'make open         Build and open the PDF.' \
		'make check        Check tools and the main source file.' \
		'make clean        Remove auxiliary files; preserve PDF and sources.' \
		'make commit       Stage all non-ignored project changes and commit locally.' \
		'make commit MSG="说明"  Commit with a custom message; does not build or push.' \
		'make help         Show this help.' \
		'' \
		'Overrides: make MAIN=main LATEXMK=/path/to/latexmk XELATEX=/path/to/xelatex' \
		'Locale: make TEX_LOCALE=en_US.UTF-8'
