#!/usr/bin/env python3
# Copyright (c) 2025 Kataglyphis
# SPDX-License-Identifier: MIT
"""Run schema-constrained GenAI generation over the shared tiny model; no download, device or real LLM."""

import argparse
import importlib.util
import json
import pathlib
import sys
import tempfile

# One legal answer, which the tiny model's successor rule never predicts from its prompt: only a live mask can produce it.
SCHEMA = {"enum": [7]}


def load_fixture(path):
    """Import the fixture writer, whose hyphenated name import statements cannot reach."""
    spec = importlib.util.spec_from_file_location("tiny_genai_model", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def generate(og, model, tokenizer, oracle, schema):
    """Decode one greedy generation, constrained when a schema is given."""
    params = og.GeneratorParams(model)
    params.set_search_options(do_sample=False, max_length=oracle["max_length"])
    if schema is not None:
        params.set_guidance("json_schema", json.dumps(schema))
    generator = og.Generator(model, params)
    generator.append_tokens(oracle["prompt_ids"])
    tokens = []
    while not generator.is_done():
        generator.generate_next_token()
        tokens.append(int(generator.get_next_tokens()[0]))
    return tokenizer.decode(tokens)


def run(fixture_script):
    """Return the constrained answer after proving the unconstrained control follows the model."""
    import onnxruntime_genai as og

    fixture = load_fixture(fixture_script)
    with tempfile.TemporaryDirectory(prefix="genai-guidance-") as directory:
        root = pathlib.Path(directory)
        oracle = fixture.write(root)
        model = og.Model(str(root))
        tokenizer = og.Tokenizer(model)
        control = generate(og, model, tokenizer, oracle, None)
        if control != oracle["continuation"]:
            raise AssertionError(f"the control run gave {control!r}, expected {oracle['continuation']!r}")
        answer = generate(og, model, tokenizer, oracle, SCHEMA)
        # The temporary directory cannot go while the native model still holds its files.
        del tokenizer, model
    return answer


def main():
    """Print the sentinel only for the one answer the schema allows."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, help="path of tiny-genai-model.py")
    answer = run(parser.parse_args().fixture)
    if json.loads(answer) != 7:
        raise AssertionError(f"the constrained answer breaks the schema: {answer!r}")
    print(f"genai-guidance-schema-ok {answer}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
