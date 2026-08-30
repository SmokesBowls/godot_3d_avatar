@tool
extends RefCounted

## edit_receipt_store.gd — Mechanical, agent-free per-edit revert.
##
## Every DIRECT_WRITE turn (hermes_bridge.gd) that actually touches the
## live project tree gets one "receipt": the exact pre-turn bytes of
## every path the turn changed, plus the post-turn SHA-256 of each path.
## A receipt's Revert button (hermes_dock.gd) restores those exact
## before-bytes. No LLM call, no prompt, no interpretation — every
## function in this file is pure filesystem mechanics.
##
## STORAGE: user://edit_receipts/<edit_id>/ — Godot's per-project user
## data dir, a wholly separate OS path from project_root() (res://'s
## target on disk — see hermes_bridge.gd's project_root()). Receipts are
## therefore structurally invisible to hermes_bridge.gd's own
## _capture_tree_fingerprint() walk, which only ever walks project_root
## — no exclusion-list entry to add or remember, no .gitignore line
## needed. receipt.json holds metadata + the changed-path list;
## blobs/<rel_path> holds the raw before-bytes for every MODIFIED/
## DELETED path (a CREATED path has no before-bytes to keep — reverting
## it just means deleting it).
##
## THE SAFETY GATE (revert()): before touching anything, every path in
## the receipt is re-hashed and compared against the receipt's own
## recorded AFTER state. If even one path no longer matches — a later
## edit touched it — the ENTIRE revert is refused, mechanically, with
## nothing touched. This is what stops an old Revert button from
## clobbering newer work (A -> B -> C, then "revert A->B" while current
## state is C: refused, because current != B).
##
## TRANSACTIONAL APPLY: once verification passes, every destination path
## is swapped via same-directory DirAccess.rename_absolute() — POSIX
## rename() overwrites its destination atomically, which is what this
## design relies on (this project runs on Linux; not asserted for
## Windows). Each destination's pre-revert bytes are preserved as a
## `<path>.hermes_revert_rollback` sidecar for the duration of the
## commit, not discarded, specifically so that if a LATER path in the
## same revert fails to commit, every already-committed path can be
## swapped back to exactly what it held a moment ago. Only once every
## path in the receipt has committed successfully are the rollback
## sidecars deleted and the receipt marked CONSUMED. A commit failure
## that recovers cleanly leaves the receipt AVAILABLE (revert can be
## retried); a commit failure that cannot recover leaves it ERROR, with
## the exact unreconciled paths reported — never silently claimed as a
## success either way.
##
## user:// and res:// are NOT assumed to share a filesystem — every temp
## file this revert path creates is written adjacent to its real
## destination inside project_root, never under user://, so the atomic
## rename is always same-directory.
##
## RETENTION (deliberate, v1): no automatic eviction. A receipt's large
## blob payload is deleted once it's CONSUMED (it can never be used
## again), but an AVAILABLE receipt is never dropped for being old or
## large — the UI promises one Revert per prompt edit, and a hidden
## keep-last-N policy would make that promise false. Byte size is
## recorded in the receipt now so a future retention policy can be
## added without changing the receipt's own shape.

const _EXCLUDED_DIR_NAMES := [".git", ".hermes_scratch"]  # duplicated from hermes_bridge.gd's own SCRATCH_DIR_NAME/exclusion list on purpose — this file intentionally has no dependency on that one's private consts; keep the two lists in sync if either ever changes.
const _SCRATCH_PREFIX := ".hermes_scratch/"
const _TMP_SUFFIX := ".hermes_revert_tmp"
const _ROLLBACK_SUFFIX := ".hermes_revert_rollback"


static func _store_root() -> String:
	return "user://edit_receipts"


static func _receipt_dir(edit_id: String) -> String:
	return _store_root().path_join(edit_id)


## Unique per turn, human-sortable, independent of Hermes's own
## session_id. Format is an implementation detail — only "sorts
## chronologically as plain text" and "collision-proof for one human
## clicking Send" are load-bearing. Example: 20260829_140412_a73f.
static func generate_edit_id() -> String:
	var dt := Time.get_datetime_dict_from_system()
	var stamp := "%04d%02d%02d_%02d%02d%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	var suffix := "%04x" % (randi() % 0x10000)
	return "%s_%s" % [stamp, suffix]


## Reads every file in project_root once — same tree shape as
## hermes_bridge.gd's own _capture_tree_fingerprint()/_walk_and_fingerprint(),
## deliberately duplicated rather than shared, because this walk needs
## to keep the actual bytes in memory afterward, not just a hash. Hashed
## from the same in-memory buffer that's kept (HashingContext, not a
## second FileAccess.get_sha256() pass) so this never reads a file twice
## to do what one read already provides. Only called for DIRECT_WRITE
## turns — SAFE/REVIEW turns keep using the cheaper hash-only fingerprint
## since nothing on disk is expected to change in that mode.
## Returns {rel_path: {"sha256": String, "bytes": PackedByteArray}}.
static func capture_tree_snapshot(project_root: String) -> Dictionary:
	var out := {}
	_walk_and_snapshot(project_root, project_root, out)
	return out


static func _walk_and_snapshot(root: String, current_dir: String, out: Dictionary) -> void:
	var dir := DirAccess.open(current_dir)
	if dir == null:
		return  # unreadable directory — degrades silently for that subtree, matching _walk_and_fingerprint()'s own behavior
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if entry_name == "." or entry_name == "..":
			entry_name = dir.get_next()
			continue
		var full_path := current_dir.path_join(entry_name)
		if dir.current_is_dir():
			if not _EXCLUDED_DIR_NAMES.has(entry_name):
				_walk_and_snapshot(root, full_path, out)
		else:
			var rel_path := full_path.trim_prefix(root)
			if rel_path.begins_with("/"):
				rel_path = rel_path.substr(1)
			var bytes := FileAccess.get_file_as_bytes(full_path)
			var ctx := HashingContext.new()
			ctx.start(HashingContext.HASH_SHA256)
			ctx.update(bytes)
			out[rel_path] = {"sha256": ctx.finish().hex_encode(), "bytes": bytes}
		entry_name = dir.get_next()
	dir.list_dir_end()


## Same comparison shape as hermes_bridge.gd's diff_tree_fingerprints(),
## but returns structured records (not display strings) carrying enough
## to persist a receipt: change_type plus each side's existence/hash.
## `before` is a capture_tree_snapshot() result; `after` is a plain
## hermes_bridge.gd _capture_tree_fingerprint() result (hash-only — the
## after side never needs bytes, only "did this path end up matching
## what the receipt expects").
static func build_receipt_paths(snapshot_before: Dictionary, fingerprint_after: Dictionary) -> Array:
	var all_paths := {}
	for k in snapshot_before.keys():
		all_paths[k] = true
	for k in fingerprint_after.keys():
		all_paths[k] = true

	var entries := []
	for path in all_paths.keys():
		var path_str := String(path)
		if path_str.begins_with(_SCRATCH_PREFIX):
			continue
		var before_hash: String = (snapshot_before.get(path, {}) as Dictionary).get("sha256", "")
		var after_hash: String = String(fingerprint_after.get(path, ""))
		if before_hash == after_hash:
			continue
		var change_type := "modified"
		if before_hash.is_empty():
			change_type = "created"
		elif after_hash.is_empty():
			change_type = "deleted"
		entries.append({
			"path": path_str,
			"change_type": change_type,
			"before_exists": not before_hash.is_empty(),
			"before_sha256": before_hash,
			"after_exists": not after_hash.is_empty(),
			"after_sha256": after_hash,
		})
	entries.sort_custom(func(a, b): return String(a["path"]) < String(b["path"]))
	return entries


## Persists one receipt for a DIRECT_WRITE turn. If the turn touched
## nothing (paths ends up empty) this deliberately writes nothing to
## disk and returns a receipt with an empty paths list — the caller
## should treat that as "no Revert button for this turn," not an error.
## If a blob fails to write, the WHOLE receipt is marked state=ERROR
## rather than silently offering a revert that can't actually restore
## every path it claims to cover.
static func create_receipt(edit_id: String, snapshot_before: Dictionary, fingerprint_after: Dictionary) -> Dictionary:
	var paths := build_receipt_paths(snapshot_before, fingerprint_after)
	var receipt := {
		"edit_id": edit_id,
		"created_unix": Time.get_unix_time_from_system(),
		"state": "AVAILABLE",
		"paths": paths,
	}
	if paths.is_empty():
		return receipt

	var dir_path := _receipt_dir(edit_id)
	DirAccess.make_dir_recursive_absolute(dir_path)
	var blobs_root := dir_path.path_join("blobs")

	var total_bytes := 0
	var backup_ok := true
	for entry in paths:
		if String(entry["change_type"]) == "created":
			continue  # nothing existed before — nothing to back up
		var rel_path: String = entry["path"]
		var bytes: PackedByteArray = (snapshot_before[rel_path] as Dictionary)["bytes"]
		var blob_path := blobs_root.path_join(rel_path)
		DirAccess.make_dir_recursive_absolute(blob_path.get_base_dir())
		var tmp_blob_path := blob_path + ".writing"
		var writer := FileAccess.open(tmp_blob_path, FileAccess.WRITE)
		if writer == null:
			backup_ok = false
			entry["backup_error"] = "open failed: %d" % FileAccess.get_open_error()
			continue
		writer.store_buffer(bytes)
		writer.close()
		if DirAccess.rename_absolute(tmp_blob_path, blob_path) != OK:
			backup_ok = false
			entry["backup_error"] = "rename into place failed"
			continue
		entry["before_size"] = bytes.size()
		total_bytes += bytes.size()

	receipt["snapshot_bytes_total"] = total_bytes
	if not backup_ok:
		receipt["state"] = "ERROR"  # can't offer a trustworthy revert if even one backup blob didn't land
	_write_receipt_json(edit_id, receipt)
	return receipt


static func _write_receipt_json(edit_id: String, receipt: Dictionary) -> bool:
	var dir_path := _receipt_dir(edit_id)
	DirAccess.make_dir_recursive_absolute(dir_path)
	var json_path := dir_path.path_join("receipt.json")
	var tmp_path := json_path + ".writing"
	var writer := FileAccess.open(tmp_path, FileAccess.WRITE)
	if writer == null:
		return false
	writer.store_string(JSON.stringify(receipt, "  "))
	writer.close()
	return DirAccess.rename_absolute(tmp_path, json_path) == OK


static func load_receipt(edit_id: String) -> Dictionary:
	var json_path := _receipt_dir(edit_id).path_join("receipt.json")
	if not FileAccess.file_exists(json_path):
		return {}
	var reader := FileAccess.open(json_path, FileAccess.READ)
	if reader == null:
		return {}
	var text := reader.get_as_text()
	reader.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


static func _remove_dir_recursive(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.include_hidden = true
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if entry_name == "." or entry_name == "..":
			entry_name = dir.get_next()
			continue
		var full := path.path_join(entry_name)
		if dir.current_is_dir():
			_remove_dir_recursive(full)
		else:
			DirAccess.remove_absolute(full)
		entry_name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


## THE mechanical revert. No parameter here is ever LLM-derived; nothing
## in this function calls Hermes or any model. See this file's own
## top-of-file doc for the verify -> prepare -> commit -> (rollback)
## shape. Returns:
##   {ok: bool, status: String, message: String, affected_paths: PackedStringArray}
## status is one of:
##   "reverted"              — full success, receipt now CONSUMED
##   "refused_missing"       — no such receipt, or it recorded no paths
##   "refused_state"         — receipt exists but isn't AVAILABLE (already CONSUMED/ERROR)
##   "refused_mismatch"      — a later edit touched one or more paths; nothing touched
##   "refused_prepare_failed"— staging the restore failed before anything destination-side was touched; nothing touched
##   "failed_recovered"      — a commit step failed, but automatic rollback fully restored the prior (post-edit) state; receipt stays AVAILABLE
##   "failed_unrecoverable"  — a commit step failed AND rollback could not fully restore it; receipt marked ERROR; affected_paths names exactly what's unreconciled
static func revert(edit_id: String, project_root: String) -> Dictionary:
	var receipt := load_receipt(edit_id)
	if receipt.is_empty():
		return {"ok": false, "status": "refused_missing", "message": "No receipt found for edit %s." % edit_id, "affected_paths": PackedStringArray()}

	if String(receipt.get("state", "")) != "AVAILABLE":
		return {"ok": false, "status": "refused_state", "message": "Edit %s is not revertible (state=%s)." % [edit_id, receipt.get("state", "?")], "affected_paths": PackedStringArray()}

	var paths: Array = receipt.get("paths", [])
	if paths.is_empty():
		return {"ok": false, "status": "refused_missing", "message": "Edit %s recorded no changed paths." % edit_id, "affected_paths": PackedStringArray()}

	# --- VERIFY: current state must exactly match every recorded AFTER state, or the whole revert is refused ---
	var mismatched: PackedStringArray = []
	for entry in paths:
		var rel_path: String = entry["path"]
		var full_path := project_root.path_join(rel_path)
		var exists := FileAccess.file_exists(full_path)
		if exists != bool(entry["after_exists"]):
			mismatched.append(rel_path)
		elif exists and FileAccess.get_sha256(full_path) != String(entry["after_sha256"]):
			mismatched.append(rel_path)
	if not mismatched.is_empty():
		return {
			"ok": false, "status": "refused_mismatch",
			"message": "Revert refused: later change(s) touched %d path(s) since this edit. Nothing was touched." % mismatched.size(),
			"affected_paths": mismatched,
		}

	# --- PREPARE: stage before-bytes into adjacent tmp files; no destination touched yet ---
	var blobs_root := _receipt_dir(edit_id).path_join("blobs")
	var prepared_tmp_paths: PackedStringArray = []
	var prepare_error := ""
	for entry in paths:
		if String(entry["change_type"]) == "created":
			continue  # nothing to stage — commit phase just removes it
		var rel_path: String = entry["path"]
		var full_path := project_root.path_join(rel_path)
		var blob_path := blobs_root.path_join(rel_path)
		if not FileAccess.file_exists(blob_path):
			prepare_error = "backup missing for %s" % rel_path
			break
		var reader := FileAccess.open(blob_path, FileAccess.READ)
		if reader == null:
			prepare_error = "could not open backup for %s" % rel_path
			break
		var bytes := reader.get_buffer(reader.get_length())
		reader.close()
		DirAccess.make_dir_recursive_absolute(full_path.get_base_dir())
		var tmp_path := full_path + _TMP_SUFFIX
		var writer := FileAccess.open(tmp_path, FileAccess.WRITE)
		if writer == null:
			prepare_error = "could not stage restore for %s" % rel_path
			break
		writer.store_buffer(bytes)
		writer.close()
		if FileAccess.get_sha256(tmp_path) != String(entry["before_sha256"]):
			prepare_error = "staged restore for %s failed an integrity check" % rel_path
			break
		prepared_tmp_paths.append(tmp_path)

	if not prepare_error.is_empty():
		for p in prepared_tmp_paths:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
		return {
			"ok": false, "status": "refused_prepare_failed",
			"message": "Revert aborted before touching the project (%s). Nothing was changed." % prepare_error,
			"affected_paths": PackedStringArray(),
		}

	# --- COMMIT: swap each destination via same-directory rename; track what's committed so a mid-way failure can roll back ---
	var committed: Array = []  # [{path, full_path, rollback_path}]
	var commit_error := ""
	for entry in paths:
		var rel_path: String = entry["path"]
		var full_path := project_root.path_join(rel_path)
		var rollback_path := full_path + _ROLLBACK_SUFFIX

		if String(entry["change_type"]) == "created":
			if DirAccess.rename_absolute(full_path, rollback_path) != OK:
				commit_error = "could not remove %s" % rel_path
				break
			committed.append({"path": rel_path, "full_path": full_path, "rollback_path": rollback_path})
		else:
			var tmp_path := full_path + _TMP_SUFFIX
			if DirAccess.rename_absolute(full_path, rollback_path) != OK:
				commit_error = "could not stage current state of %s aside" % rel_path
				break
			if DirAccess.rename_absolute(tmp_path, full_path) != OK:
				DirAccess.rename_absolute(rollback_path, full_path)  # best-effort immediate undo of the half-done swap
				commit_error = "could not install restored bytes for %s" % rel_path
				break
			committed.append({"path": rel_path, "full_path": full_path, "rollback_path": rollback_path})

	if commit_error.is_empty():
		for c in committed:
			if FileAccess.file_exists(c["rollback_path"]):
				DirAccess.remove_absolute(c["rollback_path"])
		receipt["state"] = "CONSUMED"
		_write_receipt_json(edit_id, receipt)
		_remove_dir_recursive(blobs_root)  # large payload can never be used again — see Decision 3 in this file's own doc
		var restored: PackedStringArray = []
		for c in committed:
			restored.append(String(c["path"]))
		return {"ok": true, "status": "reverted", "message": "Reverted %d path(s)." % committed.size(), "affected_paths": restored}

	# --- ROLLBACK: a commit step failed — undo every already-committed path back to its pre-revert (AFTER) state ---
	for c in committed:
		DirAccess.rename_absolute(String(c["rollback_path"]), String(c["full_path"]))
	for entry in paths:
		var leftover_tmp: String = project_root.path_join(String(entry["path"])) + _TMP_SUFFIX
		if FileAccess.file_exists(leftover_tmp):
			DirAccess.remove_absolute(leftover_tmp)

	var still_mismatched: PackedStringArray = []
	for entry in paths:
		var rel_path: String = entry["path"]
		var full_path := project_root.path_join(rel_path)
		var exists := FileAccess.file_exists(full_path)
		if exists != bool(entry["after_exists"]):
			still_mismatched.append(rel_path)
		elif exists and FileAccess.get_sha256(full_path) != String(entry["after_sha256"]):
			still_mismatched.append(rel_path)

	if still_mismatched.is_empty():
		return {
			"ok": false, "status": "failed_recovered",
			"message": "Revert failed (%s), but the original post-edit state was fully restored. The receipt remains available to try again." % commit_error,
			"affected_paths": PackedStringArray(),
		}

	receipt["state"] = "ERROR"
	_write_receipt_json(edit_id, receipt)
	return {
		"ok": false, "status": "failed_unrecoverable",
		"message": "Revert failed (%s) and automatic recovery could not fully restore the prior state. Do not trust these paths without manual inspection." % commit_error,
		"affected_paths": still_mismatched,
	}
