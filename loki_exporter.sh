#!/bin/ash -u
#
# shellcheck shell=bash
# ^^^ the above line is purely for shellcheck to treat this as a bash-like script
# (OpenWRT's ash from busybox is kinda similar but there still could be issues)

PIPE_NAME="/tmp/loki_exporter.pipe"
BULK_DATA="/tmp/loki_exporter.boot"

LOKI_MSG_TEMPLATE="{\"streams\": [{\"stream\": {\"job\": \"openwrt_loki_exporter\", \"host\": \"${HOSTNAME}\"}, \"values\": [[\"TIMESTAMP\", \"MESSAGE\"]]}]}"
LOKI_BULK_TEMPLATE_HEADER="{\"streams\": [{\"stream\": {\"job\": \"openwrt_loki_exporter\", \"host\": \"${HOSTNAME}\"}, \"values\": ["
LOKI_BULK_TEMPLATE_MSG="[\"TIMESTAMP\", \"MESSAGE\"],"
LOKI_BULK_TEMPLATE_FOOTER="]}]}"

_setup() {
    mkfifo ${PIPE_NAME}
    echo "started with BOOT=${BOOT}" >&2
}

_teardown() {
    if ! kill "${tailer_pid}"; then
        echo "tailer (${tailer_pid}) was already killed, exiting" >&2
    else
        echo "tailer ${tailer_pid} killed, exiting" >&2
    fi
    rm -f ${PIPE_NAME}
    exit 0
}

_do_bulk_post() {
    post_body="${LOKI_BULK_TEMPLATE_HEADER}"

    while read -r line; do
        ts="${line:26:14}"
        ts_ms="${ts/./}"

        # shellcheck disable=SC2116
        # subshell is required to handle multiplication errors and keep the loop
        if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
            echo "PARSE ERROR: '${line}'"
            continue
        fi

        msg="${line:42:1000}"
        msg="${msg//\"/\\\"}"

        msg_payload="${LOKI_BULK_TEMPLATE_MSG}"
        msg_payload="${msg_payload/TIMESTAMP/$ts_ns}"
        msg_payload="${msg_payload/MESSAGE/$msg}"

        post_body="${post_body}${msg_payload}"
    done <${BULK_DATA}

    post_body="${post_body:0:${#post_body}-1}${LOKI_BULK_TEMPLATE_FOOTER}"
    echo "${post_body}" | gzip >${BULK_DATA}.payload.gz
    rm -f ${BULK_DATA}

    if curl -fs -X POST -H "Content-Type: application/json" -H "Content-Encoding: gzip" -H "Authorization: Basic ${LOKI_AUTH_HEADER}" --data-binary "@${BULK_DATA}.payload.gz" "${LOKI_PUSH_URL}"; then
        if [ "${AUTOTEST}" -eq 1 ]; then
            mkdir -p results
            cp ${BULK_DATA}.payload.gz results/
        fi
        rm -f ${BULK_DATA}.payload.gz
    else
        echo "BULK POST FAILED: leaving ${BULK_DATA}.payload.gz for now"
    fi
}

_main_loop() {
    if [ "${BOOT}" -eq 1 ]; then
        TAILER_CMD="${LOGREAD} -l 50 -tf"
        BOOT=0
    else
        if [ "${EXTRA_ENTRIES}" -gt 0 ]; then
            TAILER_CMD="${LOGREAD} -l ${EXTRA_ENTRIES} -tf"
        else
            TAILER_CMD="${LOGREAD} -tf"
        fi
    fi

    ${TAILER_CMD} >${PIPE_NAME} 2>&1 &
    tailer_pid=$!

    while read -r line; do
        ts="${line:26:14}"
        ts_ms="${ts/./}"

        # shellcheck disable=SC2116
        # subshell is required to handle multiplication errors and keep the loop
        if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
            echo "PARSE ERROR: '${line}'"
            continue
        fi

        if [ "${MIN_TIMESTAMP}" -gt 0 ]; then
            if [ "${ts_ns}" -le "${MIN_TIMESTAMP}" ]; then
                continue
            fi
        fi

        msg="${line:42:1000}"
        msg="${msg//\"/\\\"}"

        post_body="${LOKI_MSG_TEMPLATE}"
        post_body="${post_body/TIMESTAMP/$ts_ns}"
        post_body="${post_body/MESSAGE/$msg}"

        if ! curl -fs -X POST -H "Content-type: application/json" -H "Authorization: Basic ${LOKI_AUTH_HEADER}" -d "${post_body}" "${LOKI_PUSH_URL}"; then
            echo "POST FAILED: '${post_body}'"
        fi

        MIN_TIMESTAMP="${ts_ns}"
    done <${PIPE_NAME}
}

_setup

MIN_TIMESTAMP=0

if [ ${BOOT} -eq 1 ]; then
    ${LOGREAD} -t >${BULK_DATA}
    last_line="$(tail -1 ${BULK_DATA})"
    ts="${last_line:26:14}"
    ts_ms="${ts/./}"

    # shellcheck disable=SC2116
    # subshell is required to handle multiplication errors
    if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
        echo "PARSE ERROR: '${last_line}'"
    else
        MIN_TIMESTAMP=${ts_ns}
    fi

    _do_bulk_post
fi

trap "_teardown" SIGINT SIGTERM EXIT

if [ ${BOOT} -eq 1 ]; then
    EXTRA_ENTRIES=0
else
    EXTRA_ENTRIES=1
fi

while true; do
    _main_loop
    if [ "${AUTOTEST}" -eq 1 ]; then
        exit 0
    fi
    echo "tailer exited, starting over" >&2
    EXTRA_ENTRIES=3
    sleep 1
done
