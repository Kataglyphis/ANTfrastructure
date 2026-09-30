# Sphinx configuration: https://www.sphinx-doc.org/en/master/usage/configuration.html

# An editable install from the DocumANTation submodule (requirements.txt).
from sphinx_kataglyphis import brand, setup_theme

# Project information

PROJECT = "ANTfrastructure"

# Author and copyright come from brand.json's identity; the URL is passed since a GitHub name may differ from the project name.
setup_theme(
    globals(),
    repository_url=f"{brand()['identity']['github_url']}/{PROJECT}",
    project_name=PROJECT,
    release="0.0.1",
    exclude_patterns=["_build", ".venv", "Thumbs.db", ".DS_Store"],
)
