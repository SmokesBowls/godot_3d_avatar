from pathlib import Path
import shutil
import subprocess


REPO = Path(__file__).resolve().parents[1]
CAPTURE_SOURCE = REPO / "scripts" / "PerceptionCapture3D.gd"


def _capture_persisted_body() -> str:
    source = CAPTURE_SOURCE.read_text(encoding="utf-8")

    start = source.find("func _capture_persisted(")

    assert start >= 0, (
        "STAGE7_DIMENSION_RED: "
        "_capture_persisted(...) is missing"
    )

    next_function = source.find("\nfunc ", start + 1)

    if next_function < 0:
        next_function = len(source)

    return source[start:next_function]


def test_godot_json_materializes_integer_dimensions_as_floats(
    tmp_path: Path,
) -> None:
    godot = shutil.which("godot")

    assert godot is not None, "Godot executable is unavailable"

    script = tmp_path / "stage7_json_number_probe.gd"

    script.write_text(
        r'''
extends SceneTree

func _initialize() -> void:
	var parsed = JSON.parse_string(
		"{\"width\":1152,\"height\":648}"
	)

	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("JSON root is not a Dictionary")
		quit(1)
		return

	var width = parsed["width"]
	var height = parsed["height"]

	print("JSON_WIDTH_TYPE=%d" % typeof(width))
	print("JSON_HEIGHT_TYPE=%d" % typeof(height))

	if typeof(width) != TYPE_FLOAT:
		push_error("width was not materialized as TYPE_FLOAT")
		quit(1)
		return

	if typeof(height) != TYPE_FLOAT:
		push_error("height was not materialized as TYPE_FLOAT")
		quit(1)
		return

	if int(width) != 1152 or int(height) != 648:
		push_error("numeric values changed")
		quit(1)
		return

	quit(0)
'''.lstrip(),
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            godot,
            "--headless",
            "--path",
            str(REPO),
            "--script",
            str(script),
        ],
        cwd=REPO,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
    )

    assert result.returncode == 0, result.stdout
    assert "JSON_WIDTH_TYPE=" in result.stdout
    assert "JSON_HEIGHT_TYPE=" in result.stdout


def test_capture_restores_persisted_dimension_wire_types_before_forwarding(
) -> None:
    body = _capture_persisted_body()

    width_normalization = (
        'persisted_viewport["width"] = viewport_width'
    )
    height_normalization = (
        'persisted_viewport["height"] = viewport_height'
    )
    forwarding_boundary = (
        "captured_at = persisted_captured_at"
    )

    width_pos = body.find(width_normalization)
    height_pos = body.find(height_normalization)
    forwarding_pos = body.find(forwarding_boundary)

    assert width_pos >= 0, (
        "STAGE7_DIMENSION_RED: persisted viewport width is not "
        "restored to the frozen integer wire type"
    )

    assert height_pos >= 0, (
        "STAGE7_DIMENSION_RED: persisted viewport height is not "
        "restored to the frozen integer wire type"
    )

    assert forwarding_pos >= 0, (
        "STAGE7_DIMENSION_RED: expected persisted capture "
        "forwarding boundary is missing"
    )

    assert width_pos < height_pos < forwarding_pos, (
        "STAGE7_DIMENSION_RED: dimension normalization must occur "
        "before the persisted metadata is forwarded"
    )
