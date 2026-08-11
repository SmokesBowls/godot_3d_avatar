from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import struct
from typing import Any, Callable
import zlib

import pytest

import hermes_session_adapter as adapter_module


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT_ROOT = PROJECT_ROOT / "snapshots"
REQUEST_ID = "req_172deebb27e9096a2e4623590bd9d951"
CLIENT_REQUEST_ID = "dragon3d_a0122b9cfa997888a7a149c50b9361db_1"
CAPTURE_ID = "cap_3adeef61cc885c35200be389b975c8d9_1"
SESSION_ID = "20260731_065008_63a62d"
PROJECT_ID = "godot_3d_avatar"
SCENE_PATH = "res://scenes/Main.tscn"
DRAGON_SCENE_PATH = "res://scenes/DragonAvatar3D.tscn"
IMAGE_SHA256 = "9dc5f0ba825f6193b15e329948a9b3e4754dfe59c22f43c09594bd7bf97fb660"
METADATA_SHA256 = "dad3fc45fe9fc9e008870aec9034c1ef9ec41615fc7e8bf173782b1cf3e2fac5"
WIDTH = 1152
HEIGHT = 648
IMAGE_WIRE_PATH = f"snapshots/perception_{CAPTURE_ID}.png"
METADATA_WIRE_PATH = f"snapshots/perception_{CAPTURE_ID}.json"
ACCEPTED_IMAGE = PROJECT_ROOT / IMAGE_WIRE_PATH
ACCEPTED_METADATA = PROJECT_ROOT / METADATA_WIRE_PATH
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class IndependentEvidenceError(ValueError):
    pass


def _reject_json_constant(value: str) -> None:
    raise IndependentEvidenceError(f"non-finite JSON constant: {value}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise IndependentEvidenceError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _strict_json_bytes(raw: bytes) -> dict[str, Any]:
    try:
        value = json.loads(
            raw.decode("utf-8"),
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_keys,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise IndependentEvidenceError("metadata is not strict JSON") from exc
    if not isinstance(value, dict):
        raise IndependentEvidenceError("metadata root is not an object")
    return value


def _read_regular_no_symlink(path: Path, maximum: int) -> bytes:
    try:
        before = path.lstat()
    except OSError as exc:
        raise IndependentEvidenceError(f"artifact is missing: {path}") from exc
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise IndependentEvidenceError("artifact is not a regular non-symlink file")
    if before.st_size <= 0 or before.st_size > maximum:
        raise IndependentEvidenceError("artifact size is invalid")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
            raise IndependentEvidenceError("artifact changed during open")
        chunks: list[bytes] = []
        remaining = maximum + 1
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        raw = b"".join(chunks)
        if not raw or len(raw) > maximum:
            raise IndependentEvidenceError("artifact read size is invalid")
        return raw
    finally:
        os.close(descriptor)


def _parse_png(raw: bytes) -> tuple[int, int]:
    if raw[:8] != PNG_SIGNATURE:
        raise IndependentEvidenceError("PNG signature differs")
    offset = 8
    chunk_index = 0
    ihdr_count = 0
    iend_count = 0
    width = height = 0
    while offset < len(raw):
        if offset + 12 > len(raw):
            raise IndependentEvidenceError("truncated PNG chunk header")
        length = struct.unpack(">I", raw[offset : offset + 4])[0]
        kind = raw[offset + 4 : offset + 8]
        data_start = offset + 8
        data_end = data_start + length
        chunk_end = data_end + 4
        if chunk_end > len(raw):
            raise IndependentEvidenceError("truncated PNG chunk")
        expected_crc = struct.unpack(">I", raw[data_end:chunk_end])[0]
        actual_crc = zlib.crc32(kind + raw[data_start:data_end]) & 0xFFFFFFFF
        if expected_crc != actual_crc:
            raise IndependentEvidenceError("PNG chunk CRC differs")
        if chunk_index == 0 and (kind != b"IHDR" or length != 13):
            raise IndependentEvidenceError("first PNG chunk is not a 13-byte IHDR")
        if kind == b"IHDR":
            ihdr_count += 1
            if length != 13:
                raise IndependentEvidenceError("IHDR length differs")
            width, height = struct.unpack(">II", raw[data_start : data_start + 8])
        if kind == b"IEND":
            iend_count += 1
            if length != 0 or chunk_end != len(raw):
                raise IndependentEvidenceError("IEND is not the final empty chunk")
        offset = chunk_end
        chunk_index += 1
    if offset != len(raw) or ihdr_count != 1 or iend_count != 1:
        raise IndependentEvidenceError("PNG chunk structure differs")
    if not 1 <= width <= 8192 or not 1 <= height <= 8192:
        raise IndependentEvidenceError("PNG dimensions are invalid")
    return width, height


def _independent_accepted_evidence() -> tuple[bytes, bytes, dict[str, Any]]:
    image_raw = _read_regular_no_symlink(ACCEPTED_IMAGE, 16_777_216)
    metadata_raw = _read_regular_no_symlink(ACCEPTED_METADATA, 262_144)
    metadata = _strict_json_bytes(metadata_raw)
    assert hashlib.sha256(image_raw).hexdigest() == IMAGE_SHA256
    assert hashlib.sha256(metadata_raw).hexdigest() == METADATA_SHA256
    assert _parse_png(image_raw) == (WIDTH, HEIGHT)
    assert metadata["schema"] == adapter_module.SNAPSHOT_SCHEMA
    assert metadata["capture_id"] == CAPTURE_ID
    assert metadata["client_request_id"] == CLIENT_REQUEST_ID
    assert metadata["project_id"] == PROJECT_ID
    assert metadata["scene_path"] == SCENE_PATH
    assert metadata["viewport"] == {
        "availability": "available",
        "image_path": IMAGE_WIRE_PATH,
        "image_sha256": IMAGE_SHA256,
        "media_type": "image/png",
        "width": WIDTH,
        "height": HEIGHT,
        "reason": None,
    }
    return image_raw, metadata_raw, metadata


def _payload(metadata_raw: bytes | None = None) -> dict[str, Any]:
    if metadata_raw is None:
        metadata_raw = ACCEPTED_METADATA.read_bytes()
    metadata = _strict_json_bytes(metadata_raw)
    captured_at = metadata["captured_at"]
    viewport = copy.deepcopy(metadata["viewport"])
    return {
        "player_input": "Describe the accepted Stage 5A viewport.",
        "game_state": {},
        "additional_context": {
            "client_request_id": CLIENT_REQUEST_ID,
            "companion_ref": "hermes_b",
            "perception": {
                "schema": adapter_module.PERCEPTION_SCHEMA,
                "perception_state": "full",
                "capture_id": CAPTURE_ID,
                "capture_event": "message_received",
                "capture_phase": "pre_dispatch_player_view.v1",
                "captured_at": captured_at,
                "project_id": PROJECT_ID,
                "scene_path": SCENE_PATH,
                "snapshot": {
                    "metadata_path": METADATA_WIRE_PATH,
                    "metadata_sha256": hashlib.sha256(metadata_raw).hexdigest(),
                    "metadata": metadata,
                },
                "viewport": viewport,
                "unavailable_reason": None,
            },
        },
        "timestamp": captured_at + 0.5,
        "request_id": REQUEST_ID,
    }


def _perception(payload: dict[str, Any]) -> dict[str, Any]:
    return payload["additional_context"]["perception"]


def _snapshot(payload: dict[str, Any]) -> dict[str, Any]:
    return _perception(payload)["snapshot"]


def _workspace(tmp_path: Path) -> Path:
    root = tmp_path / "snapshots"
    root.mkdir(parents=True)
    shutil.copyfile(ACCEPTED_IMAGE, root / ACCEPTED_IMAGE.name)
    shutil.copyfile(ACCEPTED_METADATA, root / ACCEPTED_METADATA.name)
    return tmp_path


def _adapter(project_dir: Path) -> Any:
    adapter = adapter_module.HermesSessionAdapter(
        adapter_module.AdapterConfig(project_dir=project_dir), director_bridge=object()
    )
    adapter.client.session_id = SESSION_ID
    return adapter


def _prepare(
    adapter: Any,
    payload: dict[str, Any],
    *,
    dragon_scene_path: str = DRAGON_SCENE_PATH,
) -> Any:
    boundary = getattr(adapter, "prepare_image_dispatch", None)
    if boundary is None or not callable(boundary):
        pytest.fail(
            "STAGE5B_INTENTIONAL_RED: public prepare_image_dispatch boundary is absent",
            pytrace=False,
        )
    return boundary(payload, dragon_scene_path=dragon_scene_path)


def _commands(prepared: Any) -> tuple[list[str], list[str]]:
    if isinstance(prepared, dict):
        contract = prepared.get("contract_argv")
        executable = prepared.get("executable_argv")
    else:
        contract = getattr(prepared, "contract_argv", None)
        executable = getattr(prepared, "executable_argv", None)
    assert isinstance(contract, list) and all(isinstance(item, str) for item in contract)
    assert isinstance(executable, list) and all(isinstance(item, str) for item in executable)
    return contract, executable


@pytest.fixture(autouse=True)
def zero_dispatch_guard(monkeypatch: pytest.MonkeyPatch) -> Any:
    calls: list[tuple[str, Any]] = []

    def forbidden(name: str) -> Callable[..., Any]:
        def fail(*args: Any, **kwargs: Any) -> Any:
            calls.append((name, (args, kwargs)))
            pytest.fail(f"Stage 5B preparation attempted forbidden execution: {name}")

        return fail

    monkeypatch.setattr(adapter_module.HermesCLIClient, "_run_bounded", forbidden("_run_bounded"))
    monkeypatch.setattr(adapter_module.HermesCLIClient, "chat", forbidden("chat"))
    monkeypatch.setattr(adapter_module.subprocess, "Popen", forbidden("subprocess.Popen"))
    monkeypatch.setattr(adapter_module.subprocess, "run", forbidden("subprocess.run"))
    yield calls
    assert calls == []


def _rewrite_metadata(
    project_dir: Path,
    payload: dict[str, Any],
    mutate: Callable[[dict[str, Any]], None],
) -> None:
    path = project_dir / METADATA_WIRE_PATH
    metadata = _strict_json_bytes(path.read_bytes())
    mutate(metadata)
    raw = (json.dumps(metadata, separators=(",", ":"), allow_nan=False) + "\n").encode()
    path.write_bytes(raw)
    snapshot = _snapshot(payload)
    snapshot["metadata"] = metadata
    snapshot["metadata_sha256"] = hashlib.sha256(raw).hexdigest()
    _perception(payload)["viewport"] = copy.deepcopy(metadata["viewport"])


def _valid_substitute_png(width: int = WIDTH, height: int = HEIGHT) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    scanlines = (b"\x00" + b"\x00\x00\x00\x00" * width) * height
    return PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b"")


def test_accepted_stage5a_artifacts_are_independently_revalidated() -> None:
    image_raw, metadata_raw, metadata = _independent_accepted_evidence()
    assert len(image_raw) == 43_118
    assert len(metadata_raw) == 737
    assert metadata["viewport"]["image_sha256"] == hashlib.sha256(image_raw).hexdigest()


def test_prepare_image_dispatch_is_public_reuses_validation_and_returns_exact_argv(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _independent_accepted_evidence()
    adapter = _adapter(PROJECT_ROOT)
    original_validate = adapter._validate_request
    validations: list[dict[str, Any]] = []

    def recording_validate(payload: Any, **kwargs: Any) -> Any:
        validations.append(payload)
        return original_validate(payload, validation_time=_payload()["timestamp"] + 0.5)

    monkeypatch.setattr(adapter, "_validate_request", recording_validate)
    prepared = _prepare(adapter, _payload())
    assert len(validations) == 1
    contract, executable = _commands(prepared)

    assert contract[contract.index("--profile") + 1] == "default"
    assert executable[1:3] == ["-p", "default"]
    assert executable[3] == "chat"
    assert executable[executable.index("--resume") + 1] == SESSION_ID
    assert "--no-restore-cwd" in executable
    assert executable[executable.index("--provider") + 1] == "openai-codex"
    assert executable[executable.index("-m") + 1] == "gpt-5.6-sol"
    assert contract[contract.index("--image") + 1] == str(ACCEPTED_IMAGE)
    assert executable[executable.index("--image") + 1] == str(ACCEPTED_IMAGE)
    assert Path(executable[executable.index("--image") + 1]).resolve(strict=True) == ACCEPTED_IMAGE


def test_wrong_dragon_scene_path_is_rejected() -> None:
    with pytest.raises(Exception):
        _prepare(_adapter(PROJECT_ROOT), _payload(), dragon_scene_path=SCENE_PATH)


def test_changed_png_byte_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    image = project / IMAGE_WIRE_PATH
    raw = bytearray(image.read_bytes())
    raw[-1] ^= 1
    image.write_bytes(raw)
    with pytest.raises(Exception):
        _prepare(_adapter(project), _payload())


def test_incorrect_image_sha256_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    _perception(payload)["viewport"]["image_sha256"] = "0" * 64
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)


def test_wrong_request_id_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    payload["request_id"] = "wrong_request"
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)


def test_wrong_client_request_id_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    payload["additional_context"]["client_request_id"] = (
        "dragon3d_ffffffffffffffffffffffffffffffff_9"
    )
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)


def test_wrong_capture_id_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    _perception(payload)["capture_id"] = "cap_ffffffffffffffffffffffffffffffff_9"
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)


def test_wrong_session_id_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    adapter = _adapter(project)
    adapter.client.session_id = "wrong_session"
    with pytest.raises(Exception):
        _prepare(adapter, _payload())


@pytest.mark.parametrize(
    ("field", "value"),
    [("project_id", "engain_avatar"), ("scene_path", DRAGON_SCENE_PATH)],
)
def test_wrong_host_identity_is_rejected(tmp_path: Path, field: str, value: str) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    _perception(payload)[field] = value
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)


@pytest.mark.parametrize(("field", "value"), [("width", WIDTH + 1), ("height", HEIGHT + 1)])
def test_wrong_dimensions_are_rejected(
    tmp_path: Path, field: str, value: int
) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    _rewrite_metadata(project, payload, lambda metadata: metadata["viewport"].__setitem__(field, value))
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)


def test_missing_png_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    (project / IMAGE_WIRE_PATH).unlink()
    with pytest.raises(Exception):
        _prepare(_adapter(project), _payload())


@pytest.mark.parametrize("raw", [b"", b"not a PNG"])
def test_empty_or_malformed_png_is_rejected(tmp_path: Path, raw: bytes) -> None:
    project = _workspace(tmp_path)
    (project / IMAGE_WIRE_PATH).write_bytes(raw)
    with pytest.raises(Exception):
        _prepare(_adapter(project), _payload())


def test_valid_but_substituted_png_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    substitute = _valid_substitute_png()
    assert _parse_png(substitute) == (WIDTH, HEIGHT)
    assert hashlib.sha256(substitute).hexdigest() != IMAGE_SHA256
    (project / IMAGE_WIRE_PATH).write_bytes(substitute)
    with pytest.raises(Exception):
        _prepare(_adapter(project), _payload())


def test_path_outside_snapshots_root_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    outside = tmp_path / "outside.png"
    outside.write_bytes(ACCEPTED_IMAGE.read_bytes())
    _rewrite_metadata(
        project,
        payload,
        lambda metadata: metadata["viewport"].__setitem__("image_path", str(outside)),
    )
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)


def test_symlink_substitution_is_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    image = project / IMAGE_WIRE_PATH
    outside = tmp_path / "substitute.png"
    image.rename(outside)
    image.symlink_to(outside)
    with pytest.raises(Exception):
        _prepare(_adapter(project), _payload())


def test_metadata_from_one_capture_referencing_another_image_is_rejected(
    tmp_path: Path,
) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    other_id = "cap_ffffffffffffffffffffffffffffffff_9"
    other_wire = f"snapshots/perception_{other_id}.png"
    (project / other_wire).write_bytes(_valid_substitute_png())
    _rewrite_metadata(
        project,
        payload,
        lambda metadata: metadata["viewport"].__setitem__("image_path", other_wire),
    )
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)


def test_stale_artifacts_replayed_under_altered_ids_are_rejected(tmp_path: Path) -> None:
    project = _workspace(tmp_path)
    payload = _payload()
    payload["request_id"] = "req_ffffffffffffffffffffffffffffffff"
    payload["additional_context"]["client_request_id"] = (
        "dragon3d_ffffffffffffffffffffffffffffffff_9"
    )
    _perception(payload)["capture_id"] = "cap_ffffffffffffffffffffffffffffffff_9"
    with pytest.raises(Exception):
        _prepare(_adapter(project), payload)
