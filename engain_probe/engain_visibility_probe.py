PROBE_NAME = "ENGAIN_PYTHON_VISIBILITY_TEST"
PROBE_VERSION = 1


def handshake_probe(message: str) -> dict:
    return {
        "probe": PROBE_NAME,
        "version": PROBE_VERSION,
        "received": message,
    }
