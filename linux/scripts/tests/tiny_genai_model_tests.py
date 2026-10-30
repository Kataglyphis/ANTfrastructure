"""The tiny GenAI model, read back with a stdlib protobuf walker; generation itself is proven where the wheel exists."""
import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest
from types import ModuleType

GENERATOR = pathlib.Path(sys.argv.pop(1)).resolve()


def load() -> ModuleType:
    """The generator as a fresh module, so a test may patch its constants."""
    spec = importlib.util.spec_from_file_location("tiny_genai_model", GENERATOR)
    if spec is None or spec.loader is None:
        raise ImportError(GENERATOR)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def varint(data: bytes, i: int) -> tuple[int, int]:
    """(value, next offset) of the varint at `i`."""
    value = shift = 0
    while True:
        byte = data[i]
        i += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, i


def fields(data: bytes) -> list[tuple[int, int | bytes]]:
    """Every (field number, value) of one message; only varint and length-delimited wire types occur."""
    out: list[tuple[int, int | bytes]] = []
    i = 0
    while i < len(data):
        key, i = varint(data, i)
        if key & 7 == 0:
            value, i = varint(data, i)
            out.append((key >> 3, value))
        elif key & 7 == 2:
            size, i = varint(data, i)
            out.append((key >> 3, data[i:i + size]))
            i += size
        else:
            raise AssertionError(f"unexpected wire type {key & 7}")
    return out


def get(msg: bytes, field: int) -> list:
    """All values of one field."""
    return [v for f, v in fields(msg) if f == field]


def text(msg: bytes, field: int) -> str:
    """A single string field."""
    (value,) = get(msg, field)
    return value.decode()


class TinyGenaiModel(unittest.TestCase):
    def setUp(self) -> None:
        self.gen = load()
        self.tmp = tempfile.TemporaryDirectory()
        self.out = pathlib.Path(self.tmp.name) / "model"
        self.oracle = self.gen.write(self.out)
        self.model = (self.out / "model.onnx").read_bytes()
        (self.graph,) = get(self.model, 7)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def config(self, name: str) -> dict:
        return json.loads((self.out / name).read_text(encoding="utf-8"))

    def test_the_directory_and_its_oracle(self) -> None:
        names = sorted(p.name for p in self.out.iterdir())
        self.assertEqual(["fixture.json", "genai_config.json", "model.onnx", "tokenizer.json",
                          "tokenizer_config.json"], names)
        self.assertEqual(self.oracle, self.config("fixture.json"))
        self.assertEqual({"prompt": "abc", "prompt_ids": [97, 98, 99], "continuation": "defg",
                          "continuation_ids": [100, 101, 102, 103], "max_length": 7, "eos_token_id": 256},
                         self.oracle)

    def test_the_model_header(self) -> None:
        self.assertEqual([8], get(self.model, 1))
        (opset,) = get(self.model, 8)
        self.assertEqual(([b""], [17]), (get(opset, 1), get(opset, 2)))

    def test_the_graph_wires_logits_and_the_cache(self) -> None:
        nodes = [(text(n, 4), [v.decode() for v in get(n, 1)], text(n, 2)) for n in get(self.graph, 1)]
        self.assertEqual([
            ("Gather", ["successor_logits", "input_ids"], "logits"),
            ("Gather", ["kv_table", "input_ids"], "kv_new"),
            ("Unsqueeze", ["kv_new", "head_axis"], "kv_heads"),
            ("Concat", ["past_key_values.0.key", "kv_heads"], "present.0.key"),
            ("Concat", ["past_key_values.0.value", "kv_heads"], "present.0.value"),
        ], nodes)
        concat_axes = [[(text(a, 1), get(a, 3)) for a in get(n, 5)] for n in get(self.graph, 1)][3:]
        self.assertEqual([[("axis", [2])], [("axis", [2])]], concat_axes)

    def test_the_config_names_the_graph_inputs_and_outputs(self) -> None:
        inputs = [text(v, 1) for v in get(self.graph, 11)]
        outputs = [text(v, 1) for v in get(self.graph, 12)]
        decoder = self.config("genai_config.json")["model"]["decoder"]
        named_in = [decoder["inputs"][k] for k in ("input_ids", "attention_mask")]
        named_in += [decoder["inputs"][k] % 0 for k in ("past_key_names", "past_value_names")]
        named_out = [decoder["outputs"]["logits"]]
        named_out += [decoder["outputs"][k] % 0 for k in ("present_key_names", "present_value_names")]
        self.assertEqual(inputs, named_in)
        self.assertEqual(outputs, named_out)
        self.assertEqual(1, decoder["num_hidden_layers"])

    def test_every_logit_row_picks_the_successor(self) -> None:
        tensors = {text(t, 8): t for t in get(self.graph, 5)}
        table = tensors["successor_logits"]
        vocab = self.gen.VOCAB
        self.assertEqual([vocab, vocab], get(table, 1))
        (raw,) = get(table, 9)
        rows = struct.unpack(f"<{vocab * vocab}f", raw)
        picks = [max(range(vocab), key=lambda c, r=r: rows[r * vocab + c]) for r in range(vocab)]
        self.assertEqual([min(r + 1, 256) for r in range(vocab)], picks)

    def test_byte_tokens_are_their_byte_values(self) -> None:
        vocab = self.config("tokenizer.json")["model"]["vocab"]
        self.assertEqual(257, len(vocab))
        self.assertEqual(257, len(set(vocab.values())))
        spots = (vocab["a"], vocab["\u0120"], vocab["\u0100"], vocab["\u0143"], vocab["<|endoftext|>"])
        self.assertEqual((97, 32, 0, 0xAD, 256), spots)
        self.assertEqual("GPT2Tokenizer", self.config("tokenizer_config.json")["tokenizer_class"])

    def test_a_continuation_off_the_rule_is_refused(self) -> None:
        self.gen.CONTINUATION = "dxfg"
        with self.assertRaisesRegex(AssertionError, "successor rule"):
            self.gen.write(pathlib.Path(self.tmp.name) / "broken")

    def test_the_check_mode_reports_its_verdict(self) -> None:
        run = subprocess.run([sys.executable, "-I", str(GENERATOR), "--out", str(self.out), "--check"],
                             capture_output=True, text=True, check=False)
        if importlib.util.find_spec("onnxruntime_genai") is None:
            self.assertEqual(2, run.returncode, run.stderr)
            self.assertIn("TINY-GENAI NO-GENAI", run.stderr)
        else:
            self.assertEqual(0, run.returncode, run.stderr)
            self.assertIn("TINY-GENAI OK: 'abc' -> 'defg'", run.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
