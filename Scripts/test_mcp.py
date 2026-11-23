"""Build the bundled MCP entry point and run two independent process clients."""
import os
from pathlib import Path
import shutil

from .core.paths import ROOT
from .core.process import execute, run
from .test import environment as test_environment_for
from .tools.swift import command as swift


def main():
    python = os.environ.get("MCP_PYTHON") or next(
        (path for name in ("python3.14", "python3.13", "python3.12", "python3.11", "python3.10", "python3")
         if (path := shutil.which(name))), None
    )
    if not python:
        raise ValueError("Set MCP_PYTHON to a Python 3.10+ executable for the independent MCP fixture.")
    version = run([python, "-c", "import sys; print(int(sys.version_info >= (3, 10)))"], capture=True).strip()
    if version != "1":
        raise ValueError("Set MCP_PYTHON to a Python 3.10+ executable for the independent MCP fixture.")
    environment = ROOT / "build/mcp-venv"
    if not (environment / "bin/python").is_file():
        run([python, "-m", "venv", str(environment)])
    interpreter = environment / "bin/python"
    run([str(interpreter), "-m", "pip", "install", "--disable-pip-version-check", "-r", str(ROOT / "Scripts/mcp/requirements.txt")], log="test-mcp-python.log")
    if os.environ.get("MCP_HELPER"):
        helper = Path(os.environ["MCP_HELPER"])
    else:
        run(swift(ROOT, "build", "--product", "ArxMCP", "--jobs", os.environ.get("BUILD_JOBS", "4")), log="test-mcp-helper.log")
        binary_directory = Path(run(swift(ROOT, "build", "--show-bin-path"), capture=True).strip())
        helper = binary_directory / "ArxMCP"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise ValueError("The MCP helper executable is missing or not executable.")
    test_environment = test_environment_for(dict(os.environ, ARX_MCP_TEST_HELPER=str(helper),
                            ARX_MCP_TEST_PYTHON=str(interpreter), ARX_MCP_TEST_SCRIPT=str(ROOT / "Scripts/mcp/client_fixture.py")))
    run(swift(ROOT / "Packages/services", "test", "--jobs", os.environ.get("BUILD_JOBS", "4")), env=test_environment, log="test-mcp.log")


if __name__ == "__main__":
    raise SystemExit(execute(main))
