#!/usr/bin/env python3
"""Write a tiny GenAI model whose greedy output is known in advance: every byte token predicts its successor."""
# See docs/language-ai.md § The test model

from __future__ import annotations

import argparse
import importlib
import json
import struct
import sys
from pathlib import Path

FLOAT, INT64 = 1, 7
BYTE_TOKENS = 256
EOS_ID = BYTE_TOKENS
VOCAB = BYTE_TOKENS + 1
HEAD_SIZE = 4
OPSET, IR_VERSION = 17, 8
ATTR_INT = 2
PROMPT, CONTINUATION = "abc", "defg"
CHAT_TEMPLATE = "{% for message in messages %}{{ message['content'] }}{% endfor %}"


def _varint(value: int) -> bytes:
    """Protobuf base-128 varint of a non-negative integer."""
    if value < 0:
        raise ValueError(f"negative varint {value}")
    out = bytearray()
    while value > 0x7F:
        out.append(value & 0x7F | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def _int(field: int, value: int) -> bytes:
    """A varint field."""
    return _varint(field << 3) + _varint(value)


def _len(field: int, value: bytes | str) -> bytes:
    """A length-delimited field."""
    data = value.encode() if isinstance(value, str) else value
    return _varint(field << 3 | 2) + _varint(len(data)) + data


def _tensor(name: str, dims: list[int], data_type: int, raw: bytes) -> bytes:
    """A TensorProto initializer with raw little-endian data."""
    return b"".join(_int(1, d) for d in dims) + _int(2, data_type) + _len(8, name) + _len(9, raw)


def _value_info(name: str, elem_type: int, dims: list[int | str]) -> bytes:
    """A ValueInfoProto; a str dim is symbolic."""
    shape = b"".join(_len(1, _int(1, d) if isinstance(d, int) else _len(2, d)) for d in dims)
    return _len(1, name) + _len(2, _len(1, _int(1, elem_type) + _len(2, shape)))


def _node(op: str, inputs: list[str], output: str, **ints: int) -> bytes:
    """A NodeProto with integer attributes."""
    body = b"".join(_len(1, i) for i in inputs) + _len(2, output) + _len(3, output) + _len(4, op)
    for name, value in ints.items():
        body += _len(5, _len(1, name) + _int(3, value) + _int(20, ATTR_INT))
    return body


def successor(token: int) -> int:
    """The token the model predicts after `token`."""
    return min(token + 1, EOS_ID)


def model_bytes() -> bytes:
    """The decoder: logits pick each token's successor; the KV cache grows by one embedding per token."""
    logits = bytearray()
    for row in range(VOCAB):
        logits += struct.pack(f"<{VOCAB}f", *(10.0 if col == successor(row) else 0.0 for col in range(VOCAB)))
    kv = struct.pack(f"<{VOCAB * HEAD_SIZE}f", *(row / VOCAB for row in range(VOCAB) for _ in range(HEAD_SIZE)))
    past = ["batch", 1, "past_sequence", HEAD_SIZE]
    present = ["batch", 1, "total_sequence", HEAD_SIZE]
    graph = b"".join((
        _len(1, _node("Gather", ["successor_logits", "input_ids"], "logits")),
        _len(1, _node("Gather", ["kv_table", "input_ids"], "kv_new")),
        _len(1, _node("Unsqueeze", ["kv_new", "head_axis"], "kv_heads")),
        _len(1, _node("Concat", ["past_key_values.0.key", "kv_heads"], "present.0.key", axis=2)),
        _len(1, _node("Concat", ["past_key_values.0.value", "kv_heads"], "present.0.value", axis=2)),
        _len(2, "tiny_genai"),
        _len(5, _tensor("successor_logits", [VOCAB, VOCAB], FLOAT, bytes(logits))),
        _len(5, _tensor("kv_table", [VOCAB, HEAD_SIZE], FLOAT, kv)),
        _len(5, _tensor("head_axis", [1], INT64, struct.pack("<q", 1))),
        _len(11, _value_info("input_ids", INT64, ["batch", "sequence"])),
        _len(11, _value_info("attention_mask", INT64, ["batch", "total_sequence"])),
        _len(11, _value_info("past_key_values.0.key", FLOAT, past)),
        _len(11, _value_info("past_key_values.0.value", FLOAT, past)),
        _len(12, _value_info("logits", FLOAT, ["batch", "sequence", VOCAB])),
        _len(12, _value_info("present.0.key", FLOAT, present)),
        _len(12, _value_info("present.0.value", FLOAT, present)),
    ))
    opset = _len(1, "") + _int(2, OPSET)
    return _int(1, IR_VERSION) + _len(2, "tiny-genai-model") + _len(7, graph) + _len(8, opset)


def byte_symbols() -> list[str]:
    """GPT-2's printable stand-in for each byte, so byte-level BPE can name all 256."""
    printable = [*range(0x21, 0x7F), *range(0xA1, 0xAD), *range(0xAE, 0x100)]
    symbols = {b: chr(b) for b in printable}
    extra = (chr(BYTE_TOKENS + n) for n in range(BYTE_TOKENS))
    return [symbols.get(b) or next(extra) for b in range(BYTE_TOKENS)]


def genai_config(context: int) -> dict[str, object]:
    """GenAI's config for the decoder, greedy by default."""
    decoder = {
        "filename": "model.onnx",
        "session_options": {"log_id": "tiny-genai", "provider_options": []},
        "head_size": HEAD_SIZE, "hidden_size": HEAD_SIZE,
        "num_attention_heads": 1, "num_hidden_layers": 1, "num_key_value_heads": 1,
        "inputs": {"input_ids": "input_ids", "attention_mask": "attention_mask",
                   "past_key_names": "past_key_values.%d.key", "past_value_names": "past_key_values.%d.value"},
        "outputs": {"logits": "logits",
                    "present_key_names": "present.%d.key", "present_value_names": "present.%d.value"},
    }
    model = {"type": "llama", "bos_token_id": EOS_ID, "eos_token_id": EOS_ID, "pad_token_id": EOS_ID,
             "vocab_size": VOCAB, "context_length": context, "decoder": decoder}
    search = {"do_sample": False, "num_beams": 1, "num_return_sequences": 1, "min_length": 0,
              "max_length": context, "past_present_share_buffer": False, "top_k": 1, "top_p": 1.0,
              "temperature": 1.0, "repetition_penalty": 1.0, "length_penalty": 1.0,
              "no_repeat_ngram_size": 0, "diversity_penalty": 0.0, "early_stopping": True}
    return {"model": model, "search": search}


def tokenizer() -> tuple[dict[str, object], dict[str, object]]:
    """A byte-level BPE with no merges, so token id == byte value, and its config."""
    eos = "<|endoftext|>"
    level = {"type": "ByteLevel", "add_prefix_space": False, "trim_offsets": True, "use_regex": True}
    vocab = {symbol: i for i, symbol in enumerate(byte_symbols())}
    vocab[eos] = EOS_ID
    special = {"id": EOS_ID, "content": eos, "single_word": False, "lstrip": False, "rstrip": False,
               "normalized": False, "special": True}
    tok = {"version": "1.0", "truncation": None, "padding": None, "added_tokens": [special],
           "normalizer": None, "pre_tokenizer": level, "post_processor": None, "decoder": level,
           "model": {"type": "BPE", "dropout": None, "unk_token": None, "continuing_subword_prefix": None,
                     "end_of_word_suffix": None, "fuse_unk": False, "byte_fallback": False,
                     "vocab": vocab, "merges": []}}
    config = {"tokenizer_class": "GPT2Tokenizer", "bos_token": eos, "eos_token": eos, "unk_token": eos,
              "add_bos_token": False, "add_prefix_space": False, "model_max_length": 64,
              "chat_template": CHAT_TEMPLATE}
    return tok, config


def write(out: Path) -> dict[str, object]:
    """Write the model directory and return the oracle every binding test reads."""
    out.mkdir(parents=True, exist_ok=True)
    prompt_ids = list(PROMPT.encode())
    expected_ids = list(CONTINUATION.encode())
    if [successor(t) for t in [prompt_ids[-1], *expected_ids[:-1]]] != expected_ids:
        raise AssertionError("CONTINUATION does not follow the successor rule")
    tok, tok_config = tokenizer()
    oracle = {"prompt": PROMPT, "prompt_ids": prompt_ids, "continuation": CONTINUATION,
              "continuation_ids": expected_ids, "max_length": len(prompt_ids) + len(expected_ids),
              "eos_token_id": EOS_ID}
    files = {"genai_config.json": genai_config(64), "tokenizer.json": tok,
             "tokenizer_config.json": tok_config, "fixture.json": oracle}
    for name, data in files.items():
        (out / name).write_text(json.dumps(data, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    (out / "model.onnx").write_bytes(model_bytes())
    return oracle


def check(out: Path) -> list[str]:
    """Greedy-decode the written model through the installed GenAI wheel; the mismatches, empty when it agrees."""
    og = importlib.import_module("onnxruntime_genai")
    oracle = json.loads((out / "fixture.json").read_text(encoding="utf-8"))
    model = og.Model(str(out))
    tok = og.Tokenizer(model)
    problems = []
    prompt_ids = [int(t) for t in tok.encode(oracle["prompt"])]
    if prompt_ids != oracle["prompt_ids"]:
        problems.append(f"encode({oracle['prompt']!r}) gave {prompt_ids}, expected {oracle['prompt_ids']}")
    params = og.GeneratorParams(model)
    params.set_search_options(max_length=oracle["max_length"], do_sample=False)
    gen = og.Generator(model, params)
    gen.append_tokens(prompt_ids)
    tokens = []
    while not gen.is_done():
        gen.generate_next_token()
        tokens.append(int(gen.get_next_tokens()[0]))
    if tokens != oracle["continuation_ids"]:
        problems.append(f"greedy decoding gave {tokens}, expected {oracle['continuation_ids']}")
    text = tok.decode(tokens)
    if text != oracle["continuation"]:
        problems.append(f"decode gave {text!r}, expected {oracle['continuation']!r}")
    messages = json.dumps([{"role": "user", "content": oracle["prompt"]}])
    chat = tok.apply_chat_template(messages, add_generation_prompt=False)
    if chat != oracle["prompt"]:
        problems.append(f"the chat template gave {chat!r}, expected {oracle['prompt']!r}")
    return problems


def main() -> int:
    """CLI entry: 0 written (and checked), 1 a check mismatch, 2 no GenAI wheel to check with."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path, help="model directory to write")
    parser.add_argument("--check", action="store_true", help="then greedy-decode it with onnxruntime_genai")
    args = parser.parse_args()
    oracle = write(args.out)
    if not args.check:
        print(json.dumps(oracle))
        return 0
    try:
        problems = check(args.out)
    except ModuleNotFoundError as exc:
        if exc.name != "onnxruntime_genai":
            raise
        print("TINY-GENAI NO-GENAI: onnxruntime_genai is not importable here", file=sys.stderr)
        return 2
    for problem in problems:
        print(f"TINY-GENAI FAIL: {problem}", file=sys.stderr)
    if problems:
        return 1
    print(f"TINY-GENAI OK: {oracle['prompt']!r} -> {oracle['continuation']!r} through onnxruntime_genai")
    return 0


if __name__ == "__main__":
    sys.exit(main())
