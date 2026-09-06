# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# The reusable theme package (sphinx_kataglyphis) is installed via
# requirements.txt as an editable install from the DocumANTation
# submodule under third_party/. See requirements.txt.
from sphinx_kataglyphis import brand, setup_theme

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

PROJECT = "ContainerHub"

# Author and copyright are NOT set here: setup_theme() takes them from the
# `identity` section of the submodule's style/brand.json, the same source as the
# colours and fonts. They used to be literals ("Jonas Heinle", "2025, Jonas
# Heinle") -- one of the copies that let the name drift across sixteen files
# upstream. Passing either argument still overrides the brand, so a project with
# a different author is unaffected.
#
# The repository URL is derived rather than typed for the same reason. It is
# spelled out here rather than defaulted inside setup_theme() because a repo's
# GitHub name and its Sphinx project name are not guaranteed to be the same
# string -- every consumer happens to match today, and the theme still must
# not assume it.
setup_theme(
    globals(),
    repository_url=f"{brand()['identity']['github_url']}/{PROJECT}",
    project_name=PROJECT,
    release="0.0.1",
    exclude_patterns=["_build", ".venv", "Thumbs.db", ".DS_Store"],
)
