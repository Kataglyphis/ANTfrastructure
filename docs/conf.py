# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

import sys
from pathlib import Path

# Allow importing the reusable theme package from the repo root.
_repo_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_repo_root / "sphinx-kataglyphis-theme"))

from sphinx_kataglyphis import setup_theme

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

setup_theme(
    globals(),
    repository_url="https://github.com/Kataglyphis/Kataglyphis-ContainerHub",
    project_name="Kataglyphis-ContainerHub",
    copyright_="2025, Jonas Heinle",
    author="Jonas Heinle",
    release="0.0.1",
    exclude_patterns=["_build", ".venv", "Thumbs.db", ".DS_Store", "source_templates"],
)
