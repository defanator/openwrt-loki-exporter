#!/bin/ash -u

PIPE_NAME="/tmp/loki_exporter.np"
TAILER_CMD="/sbin/logread -tf"
LOKI_PUSH_URL="https://loki.shrdlu.club/loki/api/v1/push"
LOKI_AUTH_HEADER="YXJjaGVyX3VhZTpFamlrUGlkb3Jh"
LOKI_MSG_TEMPLATE='{"streams": [{"stream": {"job": "openwrt_loki_exporter", "host": "archer-uae"}, "values": [["TIMESTAMP", "MESSAGE"]]}]}'

_setup() {
    mkfifo ${PIPE_NAME}
    echo "started with tailer=${TAILER_CMD}" >&2
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

trap "_teardown" SIGINT SIGTERM

_main_loop() {
    $TAILER_CMD >${PIPE_NAME} 2>&1 &
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

        msg="${line:42:1000}"
        msg="${msg//\"/\\\"}"

        post_body="${LOKI_MSG_TEMPLATE}"
        post_body="${post_body/TIMESTAMP/$ts_ns}"
        post_body="${post_body/MESSAGE/$msg}"

        if ! curl -fs -X POST -H "Content-type: application/json" -H "Authorization: Basic ${LOKI_AUTH_HEADER}" -d "${post_body}" "${LOKI_PUSH_URL}"; then
            # we probably should not try to emit anything here as it could lead to curl bombing
            #echo "POST FAILED ($ts_ns)" >&2
            true
        fi
    done <${PIPE_NAME}
}

_setup

while true; do
    _main_loop
    echo "tailer exited, starting over" >&2
    sleep 1
done
