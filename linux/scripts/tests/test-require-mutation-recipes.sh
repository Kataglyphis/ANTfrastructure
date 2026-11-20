#!/usr/bin/env bash
# Recipe selection and parse fixtures do not establish that a mutation fails its actual tests.
set -euo pipefail
python3 -B "$(dirname "$0")/require_mutation_recipe_tests.py"
