#!/bin/bash
# fake_hermes_slow_for_tests.sh - like fake_hermes_for_tests.sh, but
# sleeps first so a test has a deterministic window to interrupt an
# "active turn" (Stop pressed, or the owning Node/editor torn down)
# before the process would naturally finish. Used only by the teardown/
# process-lifecycle proof, not the regular logic test suite.
query=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-q) query="$2"; shift 2 ;;
		*) shift ;;
	esac
done
sleep "${FAKE_HERMES_SLEEP_SECONDS:-4}"
echo "SLOW_QUERY_RECEIVED:${query}"
echo "session_id: fake-slow-session"
