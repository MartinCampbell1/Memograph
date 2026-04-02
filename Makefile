SWIFT ?= swift
PYTHON ?= python3
VENV ?= .venv
OLLAMA ?= ollama
DIST_DIR ?= dist
APP_NAME ?= Memograph
SWIFT_TARGET ?= MyMacAgent

.PHONY: setup setup-audio setup-models build test clean run install release package notarize verify

setup: setup-audio setup-models

setup-audio:
	$(PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip
	$(VENV)/bin/pip install mlx-whisper

setup-models:
	if command -v $(OLLAMA) >/dev/null 2>&1; then \
		$(OLLAMA) pull glm-ocr; \
		$(OLLAMA) pull qwen3.5:4b; \
		$(OLLAMA) pull hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M; \
	else \
		echo "Ollama not found. Install Ollama first, then run 'make setup-models'."; \
	fi

build:
	$(SWIFT) build

test:
	$(SWIFT) test

run:
	$(SWIFT) run $(SWIFT_TARGET)

install:
	./scripts/install.sh

release:
	./scripts/build_release.sh

package:
	./scripts/package_dmg.sh

notarize:
	./scripts/notarize.sh

verify:
	./scripts/verify_release.sh

clean:
	rm -rf .build $(DIST_DIR)
