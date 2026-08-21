#!/bin/bash
# fake_hermes_for_tests.sh - a stand-in for the real `hermes` CLI, used
# only by test_hermes_bridge_logic.gd. Mimics just enough of the real
# contract (accepts the same flags hermes_bridge.gd passes, echoes back
# the -q value and a session_id line) to prove the temp-file + wrapper-
# script pipeline delivers content correctly end-to-end, without
# spending a real Hermes/LLM call on every test run.
query=""
resume=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-q) query="$2"; shift 2 ;;
		--resume) resume="$2"; shift 2 ;;
		-m|--provider) shift 2 ;;
		*) shift ;;
	esac
done
echo "QUERY_RECEIVED:${query}"
if [[ -n "$resume" ]]; then
	echo "RESUME_WAS:${resume}"
fi
echo "session_id: fake-session-abc123"
