import os
from pathlib import Path


def setup_theme(
    conf_globals: dict,
    # ---- project overrides ----
    repository_url: str = "",
    project_name: str = "",
    copyright_: str = "",
    author: str = "",
    release: str = "0.0.1",
    # ---- config overrides ----
    extensions_extra: list | None = None,
    theme_options_extra: dict | None = None,
    html_css_files_extra: list | None = None,
    **extra_conf,
) -> None:
    """Apply Kataglyphis theme defaults to a Sphinx conf.py namespace.

    Call from your project's ``conf.py``::

        from sphinx_kataglyphis import setup_theme
        setup_theme(globals(), repository_url="https://github.com/org/repo")

    Parameters
    ----------
    conf_globals:
        The ``globals()`` dict from your ``conf.py`` so this function can set
        Sphinx config variables directly.
    repository_url:
        GitHub URL for the "Edit on GitHub" / repository button.
    project_name, copyright_, author, release:
        Project metadata (optional – can also be set manually before calling).
    extensions_extra:
        Additional Sphinx extensions to append (e.g. ``["sphinx.ext.graphviz"]``).
    theme_options_extra:
        Extra ``html_theme_options`` to merge in.
    html_css_files_extra:
        Extra CSS files to load after the base theme CSS.
    **extra_conf:
        Any other Sphinx config variable (e.g. ``exclude_patterns=...``).
    """
    pkg_dir = Path(__file__).resolve().parent

    # ---- extensions ----
    extensions = ["myst_parser", "sphinx_design"]
    if extensions_extra:
        extensions.extend(extensions_extra)
    conf_globals["extensions"] = extensions

    # ---- MyST ----
    conf_globals["myst_all_links_external"] = True

    # ---- theme ----
    theme_options = {
        "use_repository_button": bool(repository_url),
        "show_navbar_depth": 2,
        "navigation_with_keys": True,
        "show_toc_level": 2,
        "secondary_sidebar_items": ["page-toc"],
        "primary_sidebar_end": [],
    }
    if repository_url:
        theme_options["repository_url"] = repository_url
    if theme_options_extra:
        theme_options |= theme_options_extra

    conf_globals["html_theme"] = "sphinx_book_theme"
    conf_globals["html_theme_options"] = theme_options

    # ---- static paths & CSS ----
    static_paths = ["_static", str(pkg_dir / "_static")]
    conf_globals["html_static_path"] = static_paths

    css_files: list[str] = ["css/custom.css"]
    if html_css_files_extra:
        css_files.extend(html_css_files_extra)
    conf_globals["html_css_files"] = css_files

    # ---- templates ----
    conf_globals.setdefault("templates_path", []).append("_templates")

    # ---- project metadata (only set if not already present) ----
    if project_name:
        conf_globals.setdefault("project", project_name)
    if copyright_:
        conf_globals.setdefault("copyright", copyright_)
    if author:
        conf_globals.setdefault("author", author)
    if release:
        conf_globals.setdefault("release", release)

    # ---- extra conf variables ----
    for key, value in extra_conf.items():
        conf_globals[key] = value
