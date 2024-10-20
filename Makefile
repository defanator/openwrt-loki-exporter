#!/usr/bin/make -f

TOPDIR := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
SELF := $(abspath $(lastword $(MAKEFILE_LIST)))

GITHUB_RUN_ID ?= 0

DATE := $(shell date +"%Y%m%d")
VERSION := $(shell git describe --tags --always --match='v[0-9]*' | cut -d '-' -f 1 | tr -d 'v')
RELEASE := $(shell git describe --tags --always --match='v[0-9]*' --long | cut -d '-' -f 2)
BUILD := $(shell git describe --tags --long --always --dirty)-$(DATE)-$(GITHUB_RUN_ID)

SHOW_ENV_VARS = \
	VERSION \
	RELEASE \
	GITHUB_RUN_ID \
	BUILD

help: ## Show help message (list targets)
	@awk 'BEGIN {FS = ":.*##"; printf "\nTargets:\n"} /^[$$()% 0-9a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}' $(SELF)

show-var-%:
	@{ \
	escaped_v="$(subst ",\",$($*))" ; \
	if [ -n "$$escaped_v" ]; then v="$$escaped_v"; else v="(undefined)"; fi; \
	printf "%-13s %s\n" "$*" "$$v"; \
	}

show-env: $(addprefix show-var-, $(SHOW_ENV_VARS)) ## Show environment details

.venv:
	python3 -m venv .venv
	$(TOPDIR)/.venv/bin/python3 -m pip install -r $(TOPDIR)/requirements.txt

venv: .venv ## Create virtualenv

.PHONY: lint
lint: | .venv ## Run linters (shellcheck for .sh, pylint for .py)
	shellcheck loki_exporter.sh
	$(TOPDIR)/.venv/bin/python3 -m pylint tests/*.py

.PHONY: fmt
fmt: | .venv ## Run formatters
	$(TOPDIR)/.venv/bin/python3 -m black tests/*.py

create-test-env: ## Spin up testing compose environment with Loki and Grafana
	docker compose -f tests/compose.yml up -d
	sleep 5
	touch $@

.PHONY: delete-test-env
delete-test-env: ## Stop and remove testing compose environment with Loki and Grafana
	docker compose -f tests/compose.yml down
	rm -f create-test-env

.PHONY: run-test-exporter
run-test-exporter: create-test-env ## Run exporter with mocking logread (BOOT=0)
	LOGREAD="./tests/logread.py" \
	BOOT=0 \
	HOSTNAME="$(shell hostname)" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	/bin/bash -u loki_exporter.sh

.PHONY: run-test-exporter-boot
run-test-exporter-boot: test-env ## Run exporter with mocking logread (BOOT=1)
	LOGREAD="./tests/logread.py" \
	BOOT=1 \
	HOSTNAME="$(shell hostname)" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	/bin/bash -u loki_exporter.sh

run-test-exporter-onetime: create-test-env ## Run one-time cycle of mocking logread + exporter (BOOT=1)
	LOGREAD="./tests/logread.py" \
	BOOT=1 \
	HOSTNAME="$(shell hostname)" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	MAX_FOLLOW_CYCLES=3 \
	AUTOTEST=1 \
	/bin/bash -u loki_exporter.sh
	touch $@

.PHONY: test
test: run-test-exporter-onetime | .venv ## Run tests
	sleep 5
	$(TOPDIR)/.venv/bin/python3 -m pytest

.PHONY: clean
clean: delete-test-env ## Clean-up
	find $(TOPDIR)/ -type f -name "*.pyc" -delete
	find $(TOPDIR)/ -type f -name "*.pyo" -delete
	find $(TOPDIR)/ -type d -name "__pycache__" -delete
	rm -f $(TOPDIR)/run-test-exporter-onetime
