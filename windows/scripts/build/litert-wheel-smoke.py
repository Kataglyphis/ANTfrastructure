# Copyright (c) 2026 Kataglyphis
# SPDX-License-Identifier: MIT
"""The built ai_edge_litert wheel runs simple_floor_op.tflite on the CPU through the Interpreter and CompiledModel APIs."""
import sys

import numpy as np
from ai_edge_litert import compiled_model, environment
from ai_edge_litert.interpreter import Interpreter

model = sys.argv[1]
interpreter = Interpreter(model_path=model)
interpreter.allocate_tensors()
inp = interpreter.get_input_details()[0]
out = interpreter.get_output_details()[0]
x = np.full(inp["shape"], 1.5, dtype=inp["dtype"])
interpreter.set_tensor(inp["index"], x)
interpreter.invoke()
floor_interpreter = interpreter.get_tensor(out["index"])
print(f"interpreter: floor(1.5) = {floor_interpreter.ravel()[:4]}")

env = environment.Environment.create()
accel = getattr(compiled_model, "HardwareAccelerator", None)
if accel is None:
    from ai_edge_litert.hardware_accelerator import HardwareAccelerator as accel
cm = compiled_model.CompiledModel.from_file(model, hardware_accel=accel.CPU, environment=env)
inputs = cm.create_input_buffers(0)
outputs = cm.create_output_buffers(0)
inputs[0].write(x.ravel().astype(np.float32))
cm.run_by_index(0, inputs, outputs)
floor_compiled = np.asarray(outputs[0].read(int(np.prod(out["shape"])), np.float32))
print(f"compiled model (CPU): floor(1.5) = {floor_compiled[:4]}")

ok = bool(np.all(floor_interpreter == 1.0)) and bool(np.all(floor_compiled == 1.0))
print(f"LITERT-WHEEL-SMOKE {'PASS' if ok else 'FAIL'}")
sys.exit(0 if ok else 1)
