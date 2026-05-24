# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = "Kataglyphis-ContainerHub"
copyright = "2025, Jonas Heinle"
author = "Jonas Heinle"
release = "0.0.1"

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

extensions = ["myst_parser", "sphinx_design"]

templates_path = ["_templates"]
exclude_patterns = ["_build", ".venv", "Thumbs.db", ".DS_Store", "source_templates"]


# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

html_theme = "sphinx_book_theme"
html_theme_options = {
    "repository_url": "https://github.com/Kataglyphis/Kataglyphis-ContainerHub",
    "use_repository_button": True,
    "show_navbar_depth": 2,
    "navigation_with_keys": True,
}
html_static_path = ["_static"]
html_css_files = ["css/custom.css"]
