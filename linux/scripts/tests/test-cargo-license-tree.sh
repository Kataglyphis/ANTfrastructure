#!/usr/bin/env bash
# Tests live offline Cargo selection; it does not prove actual binary linkage.
set -u
tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${tests_dir}/test-harness.sh"
t_skip_unless 'Cargo and Rust compiler' cargo --version
t_skip_unless 'Rust compiler' rustc --version
t_case 'live Cargo tree and metadata must agree on root, features and sources'
t_assert_ok python3 "${tests_dir}/test_cargo_license_tree.py"
t_summary
