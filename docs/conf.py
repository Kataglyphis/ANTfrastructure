# Sphinx configuration: https://www.sphinx-doc.org/en/master/usage/configuration.html

# The docs lock installs the DocumANTation theme editable from the pinned submodule.
from sphinx_kataglyphis import brand, setup_theme

# Project information

PROJECT = "ANTfrastructure"

# Author and copyright come from brand.json's identity; the URL is passed since a GitHub name may differ from the project name.
setup_theme(
    globals(),
    repository_url=f"{brand()['identity']['github_url']}/{PROJECT}",
    project_name=PROJECT,
    exclude_patterns=["_build", ".venv", "Thumbs.db", ".DS_Store"],
)

# The repository's own logo, in place of setup_theme()'s shared default.
html_logo = "../images/logo.svg"
html_favicon = html_logo
