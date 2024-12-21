#!/bin/ash -u
#
# shellcheck shell=bash
# ^^^ the above line is purely for shellcheck to treat this as a bash-like script
# (OpenWRT's ash from busybox is kinda similar but there still could be issues)

_TMPDIR="$(mktemp -d -p /tmp loki_exporter.XXXXXX)"
PIPE_NAME="/${_TMPDIR}/loki_exporter.pipe"
BULK_DATA="/${_TMPDIR}/loki_exporter.boot"

LOKI_MSG_TEMPLATE="{\"streams\": [{\"stream\": {\"job\": \"openwrt_loki_exporter\", \"host\": \"${HOSTNAME}\"}, \"values\": [[\"TIMESTAMP\", \"MESSAGE\"]]}]}"
LOKI_BULK_TEMPLATE_HEADER="{\"streams\": [{\"stream\": {\"job\": \"openwrt_loki_exporter\", \"host\": \"${HOSTNAME}\"}, \"values\": ["
LOKI_BULK_TEMPLATE_MSG="[\"TIMESTAMP\", \"MESSAGE\"],"
LOKI_BULK_TEMPLATE_FOOTER="]}]}"

DATETIME_STR_FORMAT="%a %b %d %H:%M:%S %Y"
OS=$(uname -s | tr "[:upper:]" "[:lower:]")

USER_AGENT="openwrt-loki-exporter/%% VERSION %%"
BUILD_ID="%% BUILD_ID %%"

if [ "${AUTOTEST-0}" -eq 1 ]; then
    _CURL_BULK_CMD=(curl --no-progress-meter -fv -H "Content-Type: application/json" -H "Content-Encoding: gzip" -H "Connection: close" -H "User-Agent: ${USER_AGENT}")
    _CURL_CMD=(curl --no-progress-meter -fv -H "Content-Type: application/json" -H "Connection: close" -H "User-Agent: ${USER_AGENT}")
else
    _CURL_BULK_CMD=(curl -fsS -H "Content-Type: application/json" -H "Content-Encoding: gzip" -H "Authorization: Basic ${LOKI_AUTH_HEADER}" -H "Connection: close" -H "User-Agent: ${USER_AGENT}")
    _CURL_CMD=(curl -fsS -H "Content-Type: application/json" -H "Authorization: Basic ${LOKI_AUTH_HEADER}" -H "Connection: close" -H "User-Agent: ${USER_AGENT}")
fi

_setup() {
    mkfifo "${PIPE_NAME}"
    echo "${USER_AGENT} (${BUILD_ID}) started with BOOT=${BOOT}" >&2
}

_teardown() {
    if ! kill "${tailer_pid}"; then
        echo "tailer (${tailer_pid}) was already killed, exiting" >&2
    else
        echo "tailer ${tailer_pid} killed, exiting" >&2
    fi
    rm -f "${PIPE_NAME}"
    if [ "${AUTOTEST-0}" -eq 1 ]; then
        mkdir -p results
        cp -r "${_TMPDIR}" results/
    fi
    rm -rf "${_TMPDIR}"
    exit 0
}

_do_bulk_post() {
    _log_file="$1"
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

        msg="${line:42:2000}"
        msg="${msg//\"/\\\"}"

        msg_payload="${LOKI_BULK_TEMPLATE_MSG}"
        msg_payload="${msg_payload/TIMESTAMP/$ts_ns}"
        msg_payload="${msg_payload/MESSAGE/$msg}"

        post_body="${post_body}${msg_payload}"
    done <"${_log_file}"

    post_body="${post_body:0:${#post_body}-1}${LOKI_BULK_TEMPLATE_FOOTER}"
    echo "${post_body}" | gzip >"${_log_file}.payload.gz"
    rm -f "${_log_file}"

    if ! "${_CURL_BULK_CMD[@]}" --data-binary "@${_log_file}.payload.gz" "${LOKI_PUSH_URL}" >"${_log_file}.payload.gz-response" 2>&1; then
        echo "BULK POST FAILED: leaving ${_log_file}.payload.gz for now"
    fi
}

_check_for_skewed_timestamp() {
    _log_file="$1"

    # maximum threshold for comparing timestamps between 2 subsequent log lines (ns)
    delta_threshold=86400000000000

    # incremental step for substituting timestamps of unsynchronized log lines (ns)
    step=25000000

    # step 1: search for possible skewed timestamp
    prev_ts=0
    line_n=0
    line_n_synced=0
    while read -r line; do
        ts="${line:26:14}"
        ts_ms="${ts/./}"

        # shellcheck disable=SC2116
        # subshell is required to handle multiplication errors and keep the loop
        if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
            continue
        fi

        line_n=$((line_n + 1))

        if [ "${prev_ts-0}" -eq 0 ]; then
            prev_ts=$ts_ns
        fi

        delta_t=$((ts_ns - prev_ts))
        if [ $delta_t -ge $delta_threshold ]; then
            # found a line with timestamp delta exceeding a given threshold
            line_n_synced=$line_n
            break
        fi

        prev_ts=$ts_ns
    done <"${_log_file}"

    if [ $line_n_synced -eq 0 ]; then
        # no skew detected, nothing to do
        return
    fi

    # skew detected, 1st synced line is $line_n_synced;
    # round new ts to nearest second
    ts_ns=$((ts_ns / 1000000000))
    ts_ns=$((ts_ns * 1000000000))
    new_ts=$((ts_ns - step * (line_n_synced-1)))

    # step 2: re-create boot log with fake timestamps in appropriate range
    rm -f "${_log_file}.new"
    line_n=0
    while read -r line; do
        ts="${line:26:14}"
        ts_ms="${ts/./}"

        # shellcheck disable=SC2116
        # subshell is required to handle multiplication errors and keep the loop
        if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
            continue
        fi

        line_n=$((line_n + 1))

        # for lines with valid timestamps, just print a line as is
        if [ $line_n -ge $line_n_synced ]; then
            printf "%s\n" "$line" >>"$1.new"
            continue
        fi

        # otherwise, craft a new line
        msg="${line:42:2000}"

        new_ts_s=$((new_ts / 1000000000))
        case "${OS}" in
            darwin)
                datetime_str=$(date -r "${new_ts_s}" +"${DATETIME_STR_FORMAT}")
                ;;
            *)
                datetime_str=$(date -d @"${new_ts_s}" +"${DATETIME_STR_FORMAT}")
                ;;
        esac

        new_ts_ms_rounded=$((new_ts / 1000000))
        printf "%s [%s] %s\n" "${datetime_str}" "${new_ts_ms_rounded:0:10}.${new_ts_ms_rounded:10:13}" "${msg}" >>"${_log_file}.new"

        # increase timestamp
        new_ts=$((new_ts + step))
    done <"${_log_file}"

    mv "${_log_file}.new" "${_log_file}"
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

    ${TAILER_CMD} >"${PIPE_NAME}" 2>&1 &
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

        msg="${line:42:2000}"
        msg="${msg//\"/\\\"}"

        post_body="${LOKI_MSG_TEMPLATE}"
        post_body="${post_body/TIMESTAMP/$ts_ns}"
        post_body="${post_body/MESSAGE/$msg}"

        if ! "${_CURL_CMD[@]}" -d "${post_body}" "${LOKI_PUSH_URL}"; then
            echo "POST FAILED: '${post_body}'"
        fi

        MIN_TIMESTAMP="${ts_ns}"
    done <"${PIPE_NAME}"
}

_setup

MIN_TIMESTAMP=0

if [ "${BOOT}" -eq 1 ]; then
    ${LOGREAD} -t >"${BULK_DATA}"
    last_line="$(tail -1 "${BULK_DATA}")"
    ts="${last_line:26:14}"
    ts_ms="${ts/./}"

    # shellcheck disable=SC2116
    # subshell is required to handle multiplication errors
    if ! ts_ns="$(echo $(( ts_ms * 1000 * 1000 )) )" ; then
        echo "PARSE ERROR: '${last_line}'"
    else
        MIN_TIMESTAMP=${ts_ns}
    fi

    _check_for_skewed_timestamp "${BULK_DATA}"
    _do_bulk_post "${BULK_DATA}"
fi

trap "_teardown" SIGINT SIGTERM EXIT

if [ "${BOOT}" -eq 1 ]; then
    EXTRA_ENTRIES=0
else
    EXTRA_ENTRIES=1
fi

while true; do
    _main_loop
    if [ "${AUTOTEST-0}" -eq 1 ]; then
        exit 0
    fi
    echo "tailer exited, starting over" >&2
    EXTRA_ENTRIES=3
    sleep 1
done
