#!/usr/bin/make -f

TOPDIR := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
SELF := $(abspath $(lastword $(MAKEFILE_LIST)))
UPPERDIR := $(realpath $(TOPDIR)/../)

OPENWRT_CROSSBUILD_ENV_DIR ?= $(UPPERDIR)/openwrt-crossbuild-env

LOKI_EXPORTER_SRCDIR ?= $(TOPDIR)
LOKI_EXPORTER_DSTDIR ?= $(UPPERDIR)/loki_exporter_artifacts

GITHUB_RUN_ID ?= 0
GITHUB_SHA    ?= $(shell git rev-parse --short HEAD)
VERSION_STR   ?= $(shell git describe --tags --long --dirty)

DATE    := $(shell date +"%Y%m%d")
VERSION := $(shell git describe --tags --always --match='v[0-9]*' | cut -d '-' -f 1 | tr -d 'v')
RELEASE := $(shell git describe --tags --always --match='v[0-9]*' --long | cut -d '-' -f 2)
BUILD   := $(shell git describe --tags --long --always --dirty)-$(DATE)-$(GITHUB_RUN_ID)

TEST_SHELL ?= /bin/bash

SHOW_ENV_VARS = \
	SHELL \
	VERSION \
	RELEASE \
	GITHUB_SHA \
	GITHUB_RUN_ID \
	VERSION_STR \
	BUILD \
	OPENWRT_RELEASE \
	OPENWRT_ARCH \
	OPENWRT_TARGET \
	OPENWRT_SUBTARGET \
	OPENWRT_VERMAGIC \
	TEST_SHELL

help: ## Show help message (list targets)
	@awk 'BEGIN {FS = ":.*##"; printf "\nTargets:\n"} /^[$$()% 0-9a-zA-Z_-]+:.*?##/ {printf "  \033[36m%-25s\033[0m %s\n", $$1, $$2}' $(SELF)

show-var-%:
	@{ \
	escaped_v="$(subst ",\",$($*))" ; \
	if [ -n "$$escaped_v" ]; then v="$$escaped_v"; else v="(undefined)"; fi; \
	printf "%-20s %s\n" "$*" "$$v"; \
	}

show-env: $(addprefix show-var-, $(SHOW_ENV_VARS)) ## Show environment details

export-var-%:
	@{ \
	escaped_v="$(subst ",\",$($*))" ; \
	if [ -n "$$escaped_v" ]; then v="$$escaped_v"; else v="(undefined)"; fi; \
	printf "%s=%s\n" "$*" "$$v"; \
	}

export-env: $(addprefix export-var-, $(SHOW_ENV_VARS)) ## Export environment

-include $(OPENWRT_CROSSBUILD_ENV_DIR)/Makefile.crossbuild
OPENWRT_SRCDIR ?= $(error OPENWRT_SRCDIR is not defined - might be an issue with including Makefile.crossbuild)

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

create-test-env-full: ## Spin up testing compose environment with Loki and Grafana
	docker compose -f tests/compose.yml up -d

create-test-env: ## Spin up testing compose environment with Loki
	docker compose -f tests/compose.yml up -d loki
	touch $@

CHECK_ENV_TIMEOUT ?= 30
.PHONY: wait-for-loki
wait-for-loki: create-test-env
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

.PHONY: delete-test-env
delete-test-env: ## Stop and remove testing compose environment
	docker compose -f tests/compose.yml down
	rm -f create-test-env

.PHONY: run-test-exporter
run-test-exporter: wait-for-loki ## Run exporter with mocking logread (BOOT=0)
	LOGREAD="./tests/logread.py" \
	BOOT=0 \
	HOSTNAME="$(shell hostname)" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	$(TEST_SHELL) -u loki_exporter.sh

.PHONY: run-test-exporter-boot
run-test-exporter-boot: test-env ## Run exporter with mocking logread (BOOT=1)
	LOGREAD="./tests/logread.py" \
	BOOT=1 \
	HOSTNAME="$(shell hostname)" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	$(TEST_SHELL) -u loki_exporter.sh

tests/default-timeshifted.log: tests/default.log
	$(TOPDIR)/tests/create_timeshifted_log.py >$@

run-test-exporter-onetime: wait-for-loki ## Run one-time cycle of mocking logread + exporter (BOOT=1)
	LOGREAD="./tests/logread.py" \
	BOOT=1 \
	HOSTNAME="$(shell hostname)" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	MAX_FOLLOW_CYCLES=3 \
	AUTOTEST=1 \
	START_DELAY_ON_BOOT=3 \
	$(TEST_SHELL) -u loki_exporter.sh
	touch $@

run-test-exporter-timeshifted-onetime: tests/default-timeshifted.log wait-for-loki ## Run one-time cycle of mocking logread + exporter (BOOT=1 with time unsync emulation)
	LOGREAD="./tests/logread.py --log-file tests/default-timeshifted.log" \
	BOOT=1 \
	HOSTNAME="$(shell hostname).timeshifted" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	MAX_FOLLOW_CYCLES=3 \
	AUTOTEST=1 \
	START_DELAY_ON_BOOT=3 \
	$(TEST_SHELL) -u loki_exporter.sh
	touch $@

.PHONY: test
test: run-test-exporter-onetime run-test-exporter-timeshifted-onetime | .venv results ## Run tests
	$(TOPDIR)/.venv/bin/python3 -m pytest

.PHONY: compare-logs
compare-logs: | results
	cat tests/default.log | cut -c 43- | sort >results/messages.original
	cat results/resurrected.log | cut -c 17- | sort >results/messages.resurrected
	cat results/resurrected-timeshifted.log | cut -c 17- | sort >results/messages.resurrected-timeshifted
	for target in messages.resurrected messages.resurrected-timeshifted; do \
		wc -l results/messages.original results/$${target} ; \
		diff -u results/messages.original results/$${target} ||: ; \
		test $$(diff -u results/messages.original results/$${target} | grep -- " (MOCK)$$" | wc -l) -eq 3 ; \
	done

.PHONY: save-logs
save-logs: | results
	docker logs tests-loki-1 >results/loki.log 2>&1

loki-exporter: loki_exporter.sh loki_exporter.init loki_exporter.conf
	mkdir -p $(TOPDIR)/$@
	sed \
		-e "s,%% PKG_VERSION %%,$(VERSION),g" \
		-e "s,%% PKG_RELEASE %%,$(RELEASE),g" \
		-e "s,%% BUILD_ID %%,$(BUILD),g" \
		< $(TOPDIR)/Makefile.package > $(TOPDIR)/$@/Makefile
	mkdir -p $(TOPDIR)/$@/files
	for f in loki_exporter.init loki_exporter.conf; do \
		install -m 644 $(TOPDIR)/$${f} $(TOPDIR)/$@/files/ ; \
	done
	sed \
		-e "s,%% VERSION %%,$(VERSION),g" \
		-e "s,%% BUILD_ID %%,$(BUILD),g" \
		< $(TOPDIR)/loki_exporter.sh > $(TOPDIR)/$@/files/loki_exporter.sh
	chmod 755 $(TOPDIR)/$@/files/loki_exporter.sh

.PHONY: package
package: loki-exporter ## Build OpenWRT package
	@{ \
        set -ex ; \
        cd $(OPENWRT_SRCDIR) ; \
        echo "src-link loki_exporter $(LOKI_EXPORTER_SRCDIR)" > feeds.conf ; \
        ./scripts/feeds update ; \
        ./scripts/feeds install -a ; \
        mv .config.old .config ; \
        echo "CONFIG_PACKAGE_loki-exporter=y" >> .config ; \
        make defconfig ; \
        make V=s package/loki-exporter/clean ; \
        make V=s package/loki-exporter/download ; \
        make V=s package/loki-exporter/prepare ; \
        make V=s package/loki-exporter/compile ; \
        }

.PHONY: prepare-artifacts
prepare-artifacts: ## Save loki-exporter artifacts (.ipk packages)
	@{ \
        set -ex ; \
        cd $(OPENWRT_SRCDIR) ; \
        mkdir -p $(LOKI_EXPORTER_DSTDIR) ; \
        cp bin/packages/$(OPENWRT_ARCH)/loki_exporter/loki-exporter_*.ipk $(LOKI_EXPORTER_DSTDIR)/ ; \
        }

.PHONY: clean
clean: delete-test-env ## Clean-up
	find $(TOPDIR)/ -type f -name "*.pyc" -delete
	find $(TOPDIR)/ -type f -name "*.pyo" -delete
	find $(TOPDIR)/ -type d -name "__pycache__" -delete
	rm -rf $(TOPDIR)/.pytest_cache
	rm -f $(TOPDIR)/run-test-exporter-onetime $(TOPDIR)/run-test-exporter-timeshifted-onetime
	find $(TOPDIR)/tests/ -type f -name "*.log.state" -delete
	rm -f $(TOPDIR)/tests/default-timeshifted.log
	rm -rf $(TOPDIR)/results
	rm -rf $(TOPDIR)/loki-exporter
