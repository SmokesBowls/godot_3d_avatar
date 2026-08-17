from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_3D = (ROOT / "scripts/EngAInBridge3D.gd").read_text()
BRIDGE_2D = Path("/mnt/data-drive/engain_avatar/addons/zwengain/scripts/EngAInBridge.gd").read_text()


def test_callers_use_distinct_external_caller_scoped_mailboxes() -> None:
    assert 'engain-runtime-mailboxes/dragon3d' in BRIDGE_3D
    assert 'engain-runtime-mailboxes/dragon2d' in BRIDGE_2D
    assert '/godot_engain_3d_avatar/engain_request.json' not in BRIDGE_3D
    assert 'var engain_request_file = "engain_request.json"' not in BRIDGE_2D


def test_both_callers_publish_call_identity_and_expiry() -> None:
    for source in (BRIDGE_2D, BRIDGE_3D):
        assert '"call_id"' in source
        assert '"expires_at"' in source


def test_both_callers_require_call_id_response_correlation() -> None:
    for source in (BRIDGE_2D, BRIDGE_3D):
        assert 'response_call_id' in source or 'value.get("call_id")' in source
        assert 'pending_call_id' in source or '_active_call_id' in source


def test_publication_diagnostics_remain_distinct() -> None:
    for source in (BRIDGE_2D, BRIDGE_3D):
        assert "LISTENER_ABSENT" in source
        assert "MAILBOX_BUSY" in source
        assert "MAILBOX_STALE" in source
