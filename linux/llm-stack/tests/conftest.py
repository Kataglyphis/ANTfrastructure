def pytest_configure(config):
    config.addinivalue_line("markers", "inference: tests that require model inference (slow, needs model loaded)")
