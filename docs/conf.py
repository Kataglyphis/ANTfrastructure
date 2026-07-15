# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# The reusable theme package (sphinx_kataglyphis) is installed via
# requirements.txt as an editable install from the Kataglyphis-DocumANTation
# submodule under external/. See requirements.txt.
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
    exclude_patterns=["_build", ".venv", "Thumbs.db", ".DS_Store"],
)
