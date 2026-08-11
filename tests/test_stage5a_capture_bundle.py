from __future__ import annotations

import copy
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import stat
import struct
from typing import Any

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CAPTURE_ROOT = PROJECT_ROOT / "snapshots"
PRODUCER_LOG = Path(
    "/mnt/data-drive/engain-avatar-audit/ENGAV3D-0003-STAGE5A-PRODUCER.log"
)
PRODUCER_SOURCE = PROJECT_ROOT / "scripts/PerceptionCapture3D.gd"
MAIN_SOURCE = PROJECT_ROOT / "scripts/Main.gd"

PROJECT_ID = "godot_3d_avatar"
SCENE_PATH = "res://scenes/Main.tscn"
DRAGON_SCENE_PATH = "res://scenes/DragonAvatar3D.tscn"
DRAGON_NODE_PATH = "World/DragonAvatar3D"
SESSION_ID = "20260731_065008_63a62d"
PERCEPTION_SCHEMA = "engain.runtime_perception.v1"
SNAPSHOT_SCHEMA = "engain.runtime_snapshot.v1"
PERCEPTION_RESULT_SCHEMA = "engain.runtime_perception_result.v1"
CAPTURE_EVENT = "message_received"
CAPTURE_PHASE = "pre_dispatch_player_view.v1"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_IMAGE_BYTES = 16_777_216
MAX_DIMENSION = 8192
REQUEST_ID_PATTERN = re.compile(r"^req_[0-9a-f]{32}$")
CLIENT_REQUEST_ID_PATTERN = re.compile(r"^dragon3d_[0-9a-f]{32}_[1-9][0-9]*$")
CAPTURE_ID_PATTERN = re.compile(r"^cap_[0-9a-f]{32}_[1-9][0-9]*$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN_DISPATCH_TOKENS = (
    "OS.execute",
    "hermes_session_adapter.py",
    "--resume",
    "--provider",
    "--image",
    "127.0.0.1:8081",
    "/v1/engain/parse",
    "HTTPClient",
    "HTTPRequest",
    "subprocess",
)


class BundleRejected(ValueError):
    pass


def _reject_json_constant(value: str) -> None:
    raise BundleRejected(f"non-finite JSON constant: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise BundleRejected(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _strict_json_loads(text: str) -> Any:
    try:
        value = json.loads(
            text,
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise BundleRejected("not strict JSON") from exc

    stack = [value]
    while stack:
        item = stack.pop()
        if isinstance(item, float) and not math.isfinite(item):
            raise BundleRejected("non-finite JSON number")
        if isinstance(item, dict):
            stack.extend(item.values())
        elif isinstance(item, list):
            stack.extend(item)
    return value


def _read_regular_no_symlink(path: Path, maximum: int) -> bytes:
    try:
        status = path.lstat()
    except OSError as exc:
        raise BundleRejected(f"missing artifact: {path}") from exc
    if stat.S_ISLNK(status.st_mode) or not stat.S_ISREG(status.st_mode):
        raise BundleRejected("artifact is not a regular non-symlink file")
    if status.st_size <= 0 or status.st_size > maximum:
        raise BundleRejected("artifact size is invalid")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (
            status.st_dev,
            status.st_ino,
        ):
            raise BundleRejected("artifact changed during descriptor-bound open")
        raw = b""
        while len(raw) <= maximum:
            chunk = os.read(descriptor, min(65536, maximum + 1 - len(raw)))
            if not chunk:
                break
            raw += chunk
        if not raw or len(raw) > maximum:
            raise BundleRejected("artifact read size is invalid")
        return raw
    finally:
        os.close(descriptor)


def _parse_png(raw: bytes) -> tuple[int, int]:
    if raw[:8] != PNG_SIGNATURE:
        raise BundleRejected("PNG signature differs")
    offset = 8
    chunks: list[tuple[bytes, int, int]] = []
    while offset < len(raw):
        if offset + 12 > len(raw):
            raise BundleRejected("truncated PNG chunk header")
        length = struct.unpack(">I", raw[offset : offset + 4])[0]
        chunk_type = raw[offset + 4 : offset + 8]
        data_start = offset + 8
        chunk_end = data_start + length + 4
        if chunk_end > len(raw):
            raise BundleRejected("truncated PNG chunk")
        chunks.append((chunk_type, length, data_start))
        offset = chunk_end
    if offset != len(raw) or not chunks:
        raise BundleRejected("malformed PNG chunk stream")
    if chunks[0][0] != b"IHDR" or chunks[0][1] != 13:
        raise BundleRejected("first PNG chunk is not a 13-byte IHDR")
    ihdr_chunks = [chunk for chunk in chunks if chunk[0] == b"IHDR"]
    if len(ihdr_chunks) != 1:
        raise BundleRejected("PNG must contain exactly one IHDR")
    data_start = ihdr_chunks[0][2]
    width, height = struct.unpack(">II", raw[data_start : data_start + 8])
    if not (1 <= width <= MAX_DIMENSION and 1 <= height <= MAX_DIMENSION):
        raise BundleRejected("PNG dimensions are invalid")
    return width, height


def _parse_result_log(path: Path = PRODUCER_LOG) -> dict[str, Any]:
    raw = _read_regular_no_symlink(path, 1_048_576).decode("utf-8")
    records = [
        line.removeprefix("STAGE5A_RESULT=")
        for line in raw.splitlines()
        if line.startswith("STAGE5A_RESULT=")
    ]
    if len(records) != 1:
        raise BundleRejected("producer log must contain exactly one Stage 5A result")
    result = _strict_json_loads(records[0])
    if not isinstance(result, dict):
        raise BundleRejected("producer result is not an object")
    return result


def _validate_wire_path(value: Any, expected: str, root: Path) -> Path:
    if not isinstance(value, str) or value != expected:
        raise BundleRejected("artifact wire path differs from frozen form")
    if "\\" in value or ".." in value or "://" in value or Path(value).is_absolute():
        raise BundleRejected("artifact wire path is unsafe")
    candidate = root.parent / value
    if candidate.parent != root:
        raise BundleRejected("artifact path escapes capture root")
    return candidate


def verify_bundle(
    result: dict[str, Any],
    *,
    root: Path = CAPTURE_ROOT,
    expected_request_id: str | None = None,
    expected_client_request_id: str | None = None,
    expected_capture_id: str | None = None,
) -> dict[str, Any]:
    if root.is_symlink() or not root.is_dir():
        raise BundleRejected("capture root is unavailable or substituted")
    if set(result) != {
        "status",
        "request_id",
        "client_request_id",
        "capture_id",
        "project_id",
        "scene_path",
        "dragon_scene_path",
        "dragon_node_path",
        "session_id",
        "request_timestamp",
        "metadata_path",
        "metadata_sha256",
        "perception",
        "perception_result",
    }:
        raise BundleRejected("Stage 5A result shape differs")
    if result["status"] != "PASS":
        raise BundleRejected("producer did not report PASS")

    request_id = result["request_id"]
    client_request_id = result["client_request_id"]
    capture_id = result["capture_id"]
    if not isinstance(request_id, str) or not REQUEST_ID_PATTERN.fullmatch(request_id):
        raise BundleRejected("request_id format differs")
    if not isinstance(client_request_id, str) or not CLIENT_REQUEST_ID_PATTERN.fullmatch(
        client_request_id
    ):
        raise BundleRejected("client_request_id format differs")
    if not isinstance(capture_id, str) or not CAPTURE_ID_PATTERN.fullmatch(capture_id):
        raise BundleRejected("capture_id format differs")
    if len({request_id, client_request_id, capture_id}) != 3:
        raise BundleRejected("identifiers are not distinct")
    if expected_request_id is not None and request_id != expected_request_id:
        raise BundleRejected("stale or substituted request_id")
    if expected_client_request_id is not None and client_request_id != expected_client_request_id:
        raise BundleRejected("stale or substituted client_request_id")
    if expected_capture_id is not None and capture_id != expected_capture_id:
        raise BundleRejected("stale or substituted capture_id")

    if result["project_id"] != PROJECT_ID:
        raise BundleRejected("project identity differs")
    if result["scene_path"] != SCENE_PATH:
        raise BundleRejected("root scene identity differs")
    if result["dragon_scene_path"] != DRAGON_SCENE_PATH:
        raise BundleRejected("Dragon scene identity differs")
    if result["dragon_node_path"] != DRAGON_NODE_PATH:
        raise BundleRejected("Dragon node path differs")
    if result["session_id"] != SESSION_ID:
        raise BundleRejected("session identity differs")
    request_timestamp = result["request_timestamp"]
    if (
        isinstance(request_timestamp, bool)
        or not isinstance(request_timestamp, (int, float))
        or not math.isfinite(float(request_timestamp))
        or float(request_timestamp) <= 0
    ):
        raise BundleRejected("request timestamp is invalid")

    metadata_wire = f"snapshots/perception_{capture_id}.json"
    image_wire = f"snapshots/perception_{capture_id}.png"
    metadata_path = _validate_wire_path(result["metadata_path"], metadata_wire, root)
    metadata_raw = _read_regular_no_symlink(metadata_path, 262_144)
    metadata_hash = hashlib.sha256(metadata_raw).hexdigest()
    if not SHA256_PATTERN.fullmatch(str(result["metadata_sha256"])):
        raise BundleRejected("metadata hash format differs")
    if result["metadata_sha256"] != metadata_hash:
        raise BundleRejected("metadata persisted-byte hash differs")
    try:
        metadata = _strict_json_loads(metadata_raw.decode("utf-8"))
    except UnicodeDecodeError as exc:
        raise BundleRejected("metadata is not UTF-8") from exc
    if not isinstance(metadata, dict) or set(metadata) != {
        "schema",
        "capture_id",
        "client_request_id",
        "capture_event",
        "capture_phase",
        "captured_at",
        "project_id",
        "scene_path",
        "runtime",
        "viewport",
    }:
        raise BundleRejected("snapshot metadata shape differs")
    if metadata["schema"] != SNAPSHOT_SCHEMA:
        raise BundleRejected("snapshot schema differs")
    if metadata["capture_id"] != capture_id:
        raise BundleRejected("snapshot capture_id differs")
    if metadata["client_request_id"] != client_request_id:
        raise BundleRejected("snapshot client_request_id differs")
    if metadata["capture_event"] != CAPTURE_EVENT or metadata["capture_phase"] != CAPTURE_PHASE:
        raise BundleRejected("capture event or phase differs")
    if metadata["project_id"] != PROJECT_ID or metadata["scene_path"] != SCENE_PATH:
        raise BundleRejected("snapshot host identity differs")
    captured_at = metadata["captured_at"]
    if (
        isinstance(captured_at, bool)
        or not isinstance(captured_at, (int, float))
        or not math.isfinite(float(captured_at))
        or float(captured_at) <= 0
        or float(request_timestamp) - float(captured_at) < 0
        or float(request_timestamp) - float(captured_at) > 5
    ):
        raise BundleRejected("capture timestamp is invalid or stale")
    runtime = metadata["runtime"]
    if not isinstance(runtime, dict) or set(runtime) != {
        "fps",
        "current_location",
        "inventory",
        "player_position",
    }:
        raise BundleRejected("runtime snapshot shape differs")

    viewport = metadata["viewport"]
    if not isinstance(viewport, dict) or set(viewport) != {
        "availability",
        "image_path",
        "image_sha256",
        "media_type",
        "width",
        "height",
        "reason",
    }:
        raise BundleRejected("viewport shape differs")
    if viewport["availability"] != "available" or viewport["media_type"] != "image/png":
        raise BundleRejected("validated image was not marked available PNG")
    if viewport["reason"] is not None:
        raise BundleRejected("available viewport carries an unavailable reason")
    image_path = _validate_wire_path(viewport["image_path"], image_wire, root)
    image_raw = _read_regular_no_symlink(image_path, MAX_IMAGE_BYTES)
    width, height = _parse_png(image_raw)
    if viewport["width"] != width or viewport["height"] != height:
        raise BundleRejected("declared dimensions differ from PNG IHDR")
    image_hash = hashlib.sha256(image_raw).hexdigest()
    if not SHA256_PATTERN.fullmatch(str(viewport["image_sha256"])):
        raise BundleRejected("image hash format differs")
    if viewport["image_sha256"] != image_hash:
        raise BundleRejected("image persisted-byte hash differs")

    perception = result["perception"]
    if not isinstance(perception, dict) or set(perception) != {
        "schema",
        "perception_state",
        "capture_id",
        "capture_event",
        "capture_phase",
        "captured_at",
        "project_id",
        "scene_path",
        "snapshot",
        "viewport",
        "unavailable_reason",
    }:
        raise BundleRejected("runtime perception shape differs")
    if perception != {
        "schema": PERCEPTION_SCHEMA,
        "perception_state": "full",
        "capture_id": capture_id,
        "capture_event": CAPTURE_EVENT,
        "capture_phase": CAPTURE_PHASE,
        "captured_at": captured_at,
        "project_id": PROJECT_ID,
        "scene_path": SCENE_PATH,
        "snapshot": {
            "metadata_path": metadata_wire,
            "metadata_sha256": metadata_hash,
            "metadata": metadata,
        },
        "viewport": viewport,
        "unavailable_reason": None,
    }:
        raise BundleRejected("runtime perception does not exactly correlate")

    perception_result = result["perception_result"]
    if not isinstance(perception_result, dict) or perception_result != {
        "schema": PERCEPTION_RESULT_SCHEMA,
        "requested_state": "full",
        "effective_state": "structured_only",
        "capture_id": capture_id,
        "capture_event": CAPTURE_EVENT,
        "capture_phase": CAPTURE_PHASE,
        "captured_at": captured_at,
        "metadata_sha256": metadata_hash,
        "image_sha256": image_hash,
        "structured_snapshot_supplied": False,
        "viewport_image_attached": False,
        "failure_code": None,
    }:
        raise BundleRejected("local no-provider perception result differs")
    return {
        "request_id": request_id,
        "client_request_id": client_request_id,
        "capture_id": capture_id,
        "metadata_path": metadata_path,
        "image_path": image_path,
        "metadata_sha256": metadata_hash,
        "image_sha256": image_hash,
        "width": width,
        "height": height,
    }


@pytest.fixture(scope="module")
def accepted_result() -> dict[str, Any]:
    return _parse_result_log()


@pytest.fixture(scope="module")
def accepted_bundle(accepted_result: dict[str, Any]) -> dict[str, Any]:
    return verify_bundle(accepted_result)


def _copy_bundle(tmp_path: Path, result: dict[str, Any]) -> tuple[Path, dict[str, Any]]:
    root = tmp_path / "snapshots"
    root.mkdir()
    capture_id = result["capture_id"]
    for suffix in ("png", "json"):
        source = CAPTURE_ROOT / f"perception_{capture_id}.{suffix}"
        shutil.copyfile(source, root / source.name)
    return root, copy.deepcopy(result)


def _rewrite_metadata(root: Path, result: dict[str, Any], mutate: Any) -> None:
    path = root / f"perception_{result['capture_id']}.json"
    metadata = _strict_json_loads(path.read_text(encoding="utf-8"))
    mutate(metadata)
    raw = (json.dumps(metadata, separators=(",", ":"), allow_nan=False) + "\n").encode()
    path.write_bytes(raw)
    result["metadata_sha256"] = hashlib.sha256(raw).hexdigest()
    result["perception"]["snapshot"]["metadata_sha256"] = result["metadata_sha256"]
    result["perception"]["snapshot"]["metadata"] = metadata


def test_capture_png_and_metadata_are_independently_validated(
    accepted_bundle: dict[str, Any],
) -> None:
    assert accepted_bundle["image_path"].is_file()
    assert accepted_bundle["metadata_path"].is_file()
    assert accepted_bundle["width"] > 0
    assert accepted_bundle["height"] > 0


def test_generated_ids_match_frozen_formats_and_correlate(
    accepted_result: dict[str, Any], accepted_bundle: dict[str, Any]
) -> None:
    assert REQUEST_ID_PATTERN.fullmatch(accepted_result["request_id"])
    assert CLIENT_REQUEST_ID_PATTERN.fullmatch(accepted_result["client_request_id"])
    assert CAPTURE_ID_PATTERN.fullmatch(accepted_result["capture_id"])
    assert accepted_bundle["capture_id"] == accepted_result["capture_id"]


def test_persisted_png_signature_ihdr_dimensions_and_hash_are_exact(
    accepted_bundle: dict[str, Any],
) -> None:
    raw = accepted_bundle["image_path"].read_bytes()
    assert raw[:8] == PNG_SIGNATURE
    assert raw[12:16] == b"IHDR"
    assert struct.unpack(">I", raw[8:12])[0] == 13
    assert hashlib.sha256(raw).hexdigest() == accepted_bundle["image_sha256"]


def test_stage5a_producer_has_no_provider_dispatch_route() -> None:
    if not PRODUCER_SOURCE.is_file():
        pytest.fail("STAGE5A_RED: scripts/PerceptionCapture3D.gd does not exist", pytrace=False)
    combined = PRODUCER_SOURCE.read_text(encoding="utf-8") + MAIN_SOURCE.read_text(
        encoding="utf-8"
    )
    for token in FORBIDDEN_DISPATCH_TOKENS:
        assert token not in combined


@pytest.mark.parametrize(
    ("field", "replacement"),
    [
        ("request_id", "req_ffffffffffffffffffffffffffffffff"),
        ("client_request_id", "dragon3d_ffffffffffffffffffffffffffffffff_9"),
        ("capture_id", "cap_ffffffffffffffffffffffffffffffff_9"),
    ],
)
def test_toxic_stale_or_wrong_identifiers_are_rejected(
    tmp_path: Path,
    accepted_result: dict[str, Any],
    field: str,
    replacement: str,
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    toxic[field] = replacement
    with pytest.raises(BundleRejected):
        verify_bundle(
            toxic,
            root=root,
            expected_request_id=accepted_result["request_id"],
            expected_client_request_id=accepted_result["client_request_id"],
            expected_capture_id=accepted_result["capture_id"],
        )


@pytest.mark.parametrize(
    ("field", "replacement"),
    [
        ("session_id", "wrong_session"),
        ("scene_path", DRAGON_SCENE_PATH),
        ("dragon_scene_path", SCENE_PATH),
        ("project_id", "engain_avatar"),
    ],
)
def test_toxic_wrong_identity_is_rejected(
    tmp_path: Path,
    accepted_result: dict[str, Any],
    field: str,
    replacement: str,
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    toxic[field] = replacement
    with pytest.raises(BundleRejected):
        verify_bundle(toxic, root=root)


@pytest.mark.parametrize("field", ["width", "height"])
def test_toxic_wrong_or_zero_dimensions_are_rejected(
    tmp_path: Path,
    accepted_result: dict[str, Any],
    field: str,
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    _rewrite_metadata(root, toxic, lambda metadata: metadata["viewport"].__setitem__(field, 0))
    with pytest.raises(BundleRejected):
        verify_bundle(toxic, root=root)


def test_toxic_wrong_hash_is_rejected(
    tmp_path: Path, accepted_result: dict[str, Any]
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    toxic["perception"]["viewport"]["image_sha256"] = "0" * 64
    with pytest.raises(BundleRejected):
        verify_bundle(toxic, root=root)


@pytest.mark.parametrize("mutation", ["one_byte", "bad_signature", "malformed", "duplicate_ihdr"])
def test_toxic_png_mutations_are_rejected(
    tmp_path: Path,
    accepted_result: dict[str, Any],
    mutation: str,
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    path = root / f"perception_{toxic['capture_id']}.png"
    raw = bytearray(path.read_bytes())
    if mutation == "one_byte":
        raw[-1] ^= 1
    elif mutation == "bad_signature":
        raw[0] = 0
    elif mutation == "malformed":
        del raw[-5:]
    else:
        ihdr_end = 8 + 4 + 4 + 13 + 4
        raw[ihdr_end:ihdr_end] = raw[8:ihdr_end]
    path.write_bytes(raw)
    with pytest.raises(BundleRejected):
        verify_bundle(toxic, root=root)


@pytest.mark.parametrize(
    "wire_value",
    [
        "../outside.png",
        "/tmp/outside.png",
        "snapshots/../outside.png",
        "snapshots\\outside.png",
        "snapshots/nested/outside.png",
    ],
)
def test_toxic_image_path_traversal_or_substitution_is_rejected(
    tmp_path: Path,
    accepted_result: dict[str, Any],
    wire_value: str,
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    toxic["perception"]["viewport"]["image_path"] = wire_value
    with pytest.raises(BundleRejected):
        verify_bundle(toxic, root=root)


def test_toxic_symlink_substitution_is_rejected(
    tmp_path: Path, accepted_result: dict[str, Any]
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    image = root / f"perception_{toxic['capture_id']}.png"
    target = tmp_path / "substitute.png"
    image.rename(target)
    image.symlink_to(target)
    with pytest.raises(BundleRejected):
        verify_bundle(toxic, root=root)


def test_toxic_metadata_from_capture_a_with_image_b_is_rejected(
    tmp_path: Path, accepted_result: dict[str, Any]
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    image = root / f"perception_{toxic['capture_id']}.png"
    raw = bytearray(image.read_bytes())
    raw[-1] ^= 1
    image.write_bytes(raw)
    with pytest.raises(BundleRejected):
        verify_bundle(toxic, root=root)


def test_toxic_perception_cannot_claim_full_result_without_provider_attachment(
    tmp_path: Path, accepted_result: dict[str, Any]
) -> None:
    root, toxic = _copy_bundle(tmp_path, accepted_result)
    toxic["perception_result"]["effective_state"] = "full"
    toxic["perception_result"]["viewport_image_attached"] = True
    with pytest.raises(BundleRejected):
        verify_bundle(toxic, root=root)
