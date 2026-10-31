# Port of apps/desktop/scripts/lib/steps.sh
# Prints a build as one line per step: its name, then how it went. The tools a step runs write to LOG_FILE instead, and a
# failure shows the end of the log.
#
# Sourced by the scripts that build the app. Set LOG_FILE and STEP_COUNT first; sourcing empties the log and stops the
# script at the first command that fails.

: >"${LOG_FILE}"
STEP=0
STEP_OPEN=0
STEP_START=0
RUNNING=""
RUN_LOG_START=0

step() {
    STEP=$((STEP + 1))
    printf '[%d/%d] %s... ' "${STEP}" "${STEP_COUNT}" "$1"
    echo "==> [${STEP}/${STEP_COUNT}] $1" >>"${LOG_FILE}"
    STEP_OPEN=1
    STEP_START=${SECONDS}
}

# step_done [<result>]: ends the step's line with its result and how long it took.
step_done() {
    local elapsed=$((SECONDS - STEP_START))
    if ((elapsed >= 60)); then
        elapsed="$((elapsed / 60))m $((elapsed % 60))s"
    else
        elapsed="${elapsed}s"
    fi
    echo "${1:-done} (${elapsed})"
    STEP_OPEN=0
}

# fail <message> [<log>]: ends the step that is running as failed and stops the build. With a second argument, the end of
# what the last command wrote to the log follows the message.
fail() {
    if [[ "${STEP_OPEN}" == 1 ]]; then
        echo "failed"
        STEP_OPEN=0
    fi
    echo "$1" >&2
    if [[ -n "${2:-}" ]]; then
        echo "Its output:" >&2
        tail -c "+$((RUN_LOG_START + 1))" "${LOG_FILE}" | tail -n 25 | sed 's/^/  /' >&2
    fi
    echo "Full log: ${LOG_FILE}" >&2
    exit 1
}

# run <command...>: runs a command with its output in the log, and returns its status.
run() {
    RUNNING="$*"
    RUN_LOG_START="$(stat -f %z "${LOG_FILE}")"
    "$@" >>"${LOG_FILE}" 2>&1 || return
    RUNNING=""
}

# Any command that fails stops the build here. A failure inside a command substitution is reported once, by the shell that
# runs the script.
on_error() {
    local status=$?
    if ((BASH_SUBSHELL > 0)); then
        exit "${status}"
    fi
    if [[ -n "${RUNNING}" ]]; then
        fail "This failed (exit ${status}): ${RUNNING}" log
    fi
    fail "Line ${BASH_LINENO[0]} failed (exit ${status})."
}
trap on_error ERR
