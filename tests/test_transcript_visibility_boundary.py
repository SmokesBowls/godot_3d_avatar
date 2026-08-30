from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]
PROOF = ROOT / "tests" / "transcript_visibility_boundary.gd"


def test_transcript_visibility_and_capture_boundary() -> None:
    completed = subprocess.run(
        [
            "godot",
            "--display-driver",
            "x11",
            "--path",
            str(ROOT),
            "-s",
            str(PROOF),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        timeout=60,
        check=False,
    )
    output = completed.stdout + completed.stderr
    assert completed.returncode == 0, output
    assert "TRANSCRIPT_VISIBILITY_BOUNDARY: PASS" in output, output
