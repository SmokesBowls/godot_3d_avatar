import pytest


@pytest.fixture(autouse=True)
def _default_to_presence_authority_compat_mode(monkeypatch):
    """The existing test suite predates the presence authority integration
    and exercises unrelated business logic (persistent worker lifecycle,
    mailbox mechanics, request validation) without a presence authority
    server running. Rather than requiring every one of those tests to know
    about presence authority concerns, default the whole suite to the named
    temporary-compatibility fail-open mode.

    Tests that specifically exercise the new fail-closed/PRESENCE_AUTHORITY_
    UNAVAILABLE behavior (test_presence_authority_integration.py) override
    this explicitly per-test via monkeypatch.delenv, so they still get real
    fail-closed coverage.
    """
    monkeypatch.setenv("ENGAIN_PRESENCE_AUTHORITY_FAIL_OPEN_COMPAT", "1")
