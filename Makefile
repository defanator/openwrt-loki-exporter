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

results:
	mkdir -p results

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

CHECK_ENV_TIMEOUT ?= 30
create-test-env: ## Spin up testing compose environment with Loki and Grafana
	docker compose -f tests/compose.yml up -d
	@{ \
	rc=0 ; \
	wait_timeout=$(CHECK_ENV_TIMEOUT) ; \
	loki_ready=0 ; \
	echo "waiting for loki..." ; \
	while [ $$wait_timeout -gt 0 ]; do \
		if curl -fs http://127.0.0.1:3100/ready | grep -- "ready" ; then \
			loki_ready=1 ; \
			elapsed=$$(($(CHECK_ENV_TIMEOUT) - wait_timeout)) ; \
			echo "loki is up after $$elapsed seconds" ; \
		fi ; \
		if [ $$loki_ready -gt 0 ]; then \
			break ; \
		fi ; \
		wait_timeout=$$((wait_timeout - 1)) ; \
		sleep 1 ; \
	done ; \
	if [ $$loki_ready -eq 0 ]; then \
		echo "loki is not ready after $(CHECK_ENV_TIMEOUT) seconds, giving up" ; \
		rc=1 ; \
	fi ; \
	exit $$rc ; \
	}
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
test: run-test-exporter-onetime | .venv results ## Run tests
	$(TOPDIR)/.venv/bin/python3 -m pytest

.PHONY: compare-logs
compare-logs: | results
	cat tests/default.log | cut -c 43- | sort >results/messages.original
	cat results/resurrected.log | cut -c 17- | sort >results/messages.resurrected
	wc -l results/messages.original results/messages.resurrected
	diff -u results/messages.original results/messages.resurrected ||:
	test $$(diff -u results/messages.original results/messages.resurrected | grep -- " (MOCK)$$" | wc -l) -eq 3

.PHONY: save-logs
save-logs: | results
	docker logs tests-loki-1 >results/loki.log 2>&1

.PHONY: clean
clean: delete-test-env ## Clean-up
	find $(TOPDIR)/ -type f -name "*.pyc" -delete
	find $(TOPDIR)/ -type f -name "*.pyo" -delete
	find $(TOPDIR)/ -type d -name "__pycache__" -delete
	rm -f $(TOPDIR)/run-test-exporter-onetime
	find $(TOPDIR)/tests/ -type f -name "*.log.state" -delete
	rm -rf $(TOPDIR)/results
