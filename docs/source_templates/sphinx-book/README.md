# Sphinx Book Theme Template Kit

This folder contains reusable files to bootstrap a documentation website across multiple repositories.

## Included files

- `conf_base.py` – baseline Sphinx theme settings for `sphinx-book-theme`
- `custom.css` – shared visual style (light/dark mode)
- `index_template.rst` – modern landing page template with cards

## Usage in another repository

1. Copy files into your docs tree:

```bash
mkdir -p docs/source/_static/css
cp ExternalLib/Kataglyphis-ContainerHub/docs/source_templates/sphinx-book/custom.css docs/source/_static/css/custom.css
cp ExternalLib/Kataglyphis-ContainerHub/docs/source_templates/sphinx-book/index_template.rst docs/source/index.rst
```

2. Add dependencies to your `requirements.txt`:

```text
sphinx-book-theme
sphinx_design
myst-parser
```

3. Configure `docs/source/conf.py`:

```python
extensions = ["myst_parser", "sphinx_design"]
html_theme = "sphinx_book_theme"
html_static_path = ["_static"]
html_css_files = ["css/custom.css"]
```

4. Build docs as usual.
