"""onnx and onnxruntime in one process on the shared libonnx and libprotobuf."""

import ctypes
import os

import onnxruntime as ort  # noqa: I001 - before onnx on purpose, that order broke first

import numpy as np
import onnx
from onnx import TensorProto, helper
from onnx.reference import ReferenceEvaluator

weight = (np.arange(12, dtype=np.float32).reshape(3, 4) * 0.25) - 1.0
bias = 0.5 - 0.3 * np.arange(4, dtype=np.float32)
model = helper.make_model(
    helper.make_graph(
        [
            helper.make_node("MatMul", ["x", "w"], ["xw"]),
            helper.make_node("Add", ["xw", "b"], ["z"]),
            helper.make_node("Relu", ["z"], ["y"]),
        ],
        "interop",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [2, 3])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, [2, 4])],
        [
            helper.make_tensor("w", TensorProto.FLOAT, [3, 4], weight.flatten().tolist()),
            helper.make_tensor("b", TensorProto.FLOAT, [4], bias.tolist()),
        ],
    ),
    opset_imports=[helper.make_operatorsetid("", 21)],
)
model.ir_version = 10
onnx.checker.check_model(model, full_check=True)
inferred = onnx.shape_inference.infer_shapes(model, strict_mode=True)
assert any(v.name == "z" for v in inferred.graph.value_info), "onnx did not infer 'z'"

serialized = model.SerializeToString()
feeds = {"x": np.linspace(-0.2, 0.5, 6, dtype=np.float32).reshape(2, 3)}
expected = ReferenceEvaluator(model).run(None, feeds)[0]

gpu = False
try:
    cuda = ctypes.CDLL("libcuda.so.1")
    count = ctypes.c_int(0)
    gpu = cuda.cuInit(0) == 0 and cuda.cuDeviceGetCount(ctypes.byref(count)) == 0 and count.value > 0
except OSError:
    pass

available = ort.get_available_providers()
providers = ["CPUExecutionProvider"]
if "CoreMLExecutionProvider" in available:
    providers.append("CoreMLExecutionProvider")
if "CUDAExecutionProvider" in available and gpu:
    providers.append(("CUDAExecutionProvider", {"use_tf32": "0"}))
elif os.environ.get("ONNXRUNTIME_TEST_REQUIRE_CUDA") == "1":
    raise AssertionError(f"ONNXRUNTIME_TEST_REQUIRE_CUDA=1 but no usable GPU; have {available}")

for provider in providers:
    name = provider[0] if isinstance(provider, tuple) else provider
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    session = ort.InferenceSession(serialized, options, providers=[provider])
    assert name in session.get_providers(), f"{name} fell back to {session.get_providers()}"
    tol = 2e-2 if name == "CoreMLExecutionProvider" else 1e-4
    np.testing.assert_allclose(session.run(None, feeds)[0], expected, rtol=tol, atol=tol)
    print("ok", name)

onnx.checker.check_model(onnx.load_model_from_string(serialized), full_check=True)
print("ok onnx still checks models after onnxruntime registered its schemas")
