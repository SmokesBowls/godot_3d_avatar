extends SceneTree

## Real, executed proof for EngAInBridge3D._compute_wait_timeout_sec() —
## the 2026-09-13 fix that stopped the game's own outermost mailbox
## watchdog from being an independent hardcoded 180.0: equal to (and,
## after that day's earlier timeout-hierarchy fix, shorter than) the
## real underlying dispatch budgets it's supposed to be waiting on.
##
## Env-var-dependent scenarios are run as SEPARATE godot subprocess
## invocations of this same script (see the three invocations in that
## day's receipt), not mutated mid-process — Godot's OS singleton
## exposes get_environment()/has_environment() but no
## set_environment() GDScript can call; env vars are read once at
## process start, exactly like the Python side's own os.environ.get()
## calls. This script reads its own expected answer from
## EXPECTED_WAIT_TIMEOUT_SEC (test-only, never a real production env
## var) so one script drives every scenario instead of three near-
## duplicate files.
##
## Run: godot --headless -s tests/test_engainbridge3d_wait_timeout.gd
## (with EXPECTED_WAIT_TIMEOUT_SEC and whichever real env vars the
## scenario needs already set in the shell that launches it)

const Bridge := preload("res://scripts/EngAInBridge3D.gd")

func _init() -> void:
	var computed: float = Bridge._compute_wait_timeout_sec()
	var expected_raw := OS.get_environment("EXPECTED_WAIT_TIMEOUT_SEC")
	if expected_raw.is_empty():
		print("FAIL: EXPECTED_WAIT_TIMEOUT_SEC not set in the environment for this run")
		quit(1)
		return
	var expected := float(expected_raw)
	if computed == expected:
		print("OK computed=%s expected=%s" % [computed, expected])
		quit(0)
	else:
		print("FAIL computed=%s expected=%s" % [computed, expected])
		quit(1)
