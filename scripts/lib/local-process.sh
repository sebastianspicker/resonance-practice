#!/usr/bin/env bash
# Source-only helpers for local child-process lifecycle management.

local_process_is_running() {
	kill -0 "$1" >/dev/null 2>&1
}

print_local_process_message() {
	if [[ -n "$1" ]]; then
		echo "$1"
	fi
}

wait_for_local_process_exit() {
	local pid="$1"
	local timeout_seconds="$2"
	local attempt

	for ((attempt=0; attempt<timeout_seconds; attempt++)); do
		local_process_is_running "$pid" || return 0
		sleep 1
	done
}

terminate_local_process() {
	local pid="$1"
	local timeout_seconds="$2"
	local graceful_message="$3"
	local timeout_message="$4"

	print_local_process_message "$graceful_message"
	kill -TERM "$pid" >/dev/null 2>&1 || true
	wait_for_local_process_exit "$pid" "$timeout_seconds"
	if local_process_is_running "$pid"; then
		print_local_process_message "$timeout_message" >&2
		kill -KILL "$pid" >/dev/null 2>&1 || true
	fi
}

# Stops and reaps one local child process. Arguments are PID, timeout seconds
# (default 20), graceful-stop message, and timeout message.
stop_local_process() {
	local pid="${1:-}"
	local timeout_seconds="${2:-20}"
	local graceful_message="${3:-}"
	local timeout_message="${4:-}"

	[[ -n "$pid" ]] || return 0
	if local_process_is_running "$pid"; then
		terminate_local_process "$pid" "$timeout_seconds" "$graceful_message" "$timeout_message"
	fi

	wait "$pid" >/dev/null 2>&1 || true
}
