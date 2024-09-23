#!/usr/bin/make -f

help:
	echo "help will be here"

.PHONY: test-env
test-env:
	docker compose up -d

.PHONY: test-boot
test-boot: test-env
	LOGREAD="./logread.py" \
	BOOT=1 \
	HOSTNAME="$(shell hostname)" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	/bin/bash -u fake_exporter.sh

.PHONY: test
test: test-env
	LOGREAD="./logread.py" \
	BOOT=0 \
	HOSTNAME="$(shell hostname)" \
	LOKI_PUSH_URL="http://127.0.0.1:3100/loki/api/v1/push" \
	LOKI_AUTH_HEADER="none" \
	/bin/bash -u fake_exporter.sh

.PHONY: clean
clean:
	docker compose down
