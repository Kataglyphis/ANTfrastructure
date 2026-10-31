"""Hand-counted fixtures for the report-only Rust, Dart, C/C++ and Python unit readers in lang_units.py."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import lang_units

RUST = """use std::fmt;
/// doc with { brace
pub struct S<'a> {
    x: &'a str,
}
impl<'a> S<'a> {
    pub fn new(x: &'a str) -> Self {
        let c = '{';
        let r = r#"}"#;
        /* outer /* inner */ } */
        Self { x }
    }
}
#[test]
fn t() -> Result<(), String> {
    let f = |x: u8| { x + 1 };
    Ok(())
}
"""
DART = '''class A extends B {
  int get size {
    return 1;
  }
  @override
  Widget build(BuildContext c) {
    final s = "x ${c.map((e) { return "}"; })} y";
    final t = r'}';
    final u = """
}""";
    return s;
  }
  A({required this.x}) : super() {
  }
}
void main() {
}
'''
CPP = """#include <x>
#define M(a) do { a; } while (0)
namespace ns {
template <typename T = int>
static int add(int a, int b = 3) noexcept {
  const char* s = "}{";  // }
  char c = '{';
  auto r = R"x({{)x";
  if (a) { return 1; }
  return a + b;
}
class Foo : public Bar {
 public:
  Foo() : a_{1}, b_(2) {
    x();
  }
  ~Foo() override {}
  bool operator==(const Foo& o) const { return true; }
  int v = 1'000'000;
};
}  // namespace ns
extern "C" int c_api(void) {
  /* { */
  return 0;
}
auto lam = [](int x) { return x; };
"""
PYTHON = '''import os


@decorator
def first(a):
    """Doc."""
    return a  # trailing


class K:
    def method(self):
        def inner():
            return 1
        return inner

    value = 3
x = f"{os.sep}"
'''


class BraceLanguages(unittest.TestCase):
    """(name, first line, line count) per outermost function, counted by hand."""

    def test_rust(self) -> None:
        self.assertEqual([("new", 7, 6), ("t", 15, 4)], lang_units.functions(RUST, "rust"))

    def test_dart(self) -> None:
        self.assertEqual([("size", 2, 3), ("build", 6, 7), ("A", 13, 2), ("main", 16, 2)],
                         lang_units.functions(DART, "dart"))

    def test_cpp(self) -> None:
        self.assertEqual([("add", 5, 7), ("Foo", 14, 3), ("~Foo", 17, 1), ("operator==", 18, 1),
                          ("c_api", 22, 4)], lang_units.functions(CPP, "c-cpp"))

    def test_mask_keeps_lines(self) -> None:
        for text, lang in ((RUST, "rust"), (DART, "dart"), (CPP, "c-cpp")):
            masked = lang_units.mask(text, lang)
            self.assertEqual(len(text), len(masked))
            self.assertEqual(text.count("\n"), masked.count("\n"))


class PythonUnits(unittest.TestCase):
    def test_units_and_masking(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "sample.py"
            path.write_text(PYTHON, encoding="utf-8")
            units = lang_units.py_units(path)
            (path.parent / "broken.py").write_text("def broken(:\n", encoding="utf-8")
            broken = lang_units.py_units(path.parent / "broken.py")
        self.assertEqual([1, 4, 10, 11, 16], [start for start, _text in units])
        text = dict(units)
        self.assertNotIn("Doc", text[4])
        self.assertNotIn("trailing", text[4])
        self.assertIn("def inner", text[11])
        self.assertNotIn("os.sep", text[16])
        self.assertEqual([], broken)


if __name__ == "__main__":
    unittest.main()
