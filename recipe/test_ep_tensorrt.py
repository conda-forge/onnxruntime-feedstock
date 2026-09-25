"""The TensorRT EP library loads from where onnxruntime searches, and runs."""

import ctypes
import os

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper
from onnx.reference import ReferenceEvaluator

capi = os.path.join(os.path.dirname(ort.__file__), "capi")
mode = os.RTLD_NOW | os.RTLD_GLOBAL
ctypes.CDLL(os.path.join(capi, "libonnxruntime_providers_shared.so"), mode=mode)
library = os.path.join(capi, "libonnxruntime_providers_tensorrt.so")
assert os.path.exists(library), f"{library} missing; capi holds {sorted(os.listdir(capi))}"
ctypes.CDLL(library, mode=mode)
print("ok the TensorRT EP library loads from", capi)

gpu = False
try:
    cuda = ctypes.CDLL("libcuda.so.1")
    count = ctypes.c_int(0)
    gpu = cuda.cuInit(0) == 0 and cuda.cuDeviceGetCount(ctypes.byref(count)) == 0 and count.value > 0
except OSError:
    pass
if not gpu:
    assert os.environ.get("ONNXRUNTIME_TEST_REQUIRE_TENSORRT") != "1", "no usable NVIDIA GPU"
    print("skip running a model on TensorRT (no usable NVIDIA GPU)")
    raise SystemExit(0)

weight = np.arange(12, dtype=np.float32).reshape(4, 3) / 12.0
model = helper.make_model(
    helper.make_graph(
        [helper.make_node("MatMul", ["x", "w"], ["xw"]), helper.make_node("Relu", ["xw"], ["y"])],
        "trt",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [2, 4])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, [2, 3])],
        [helper.make_tensor("w", TensorProto.FLOAT, [4, 3], weight.flatten().tolist())],
    ),
    opset_imports=[helper.make_operatorsetid("", 21)],
)
model.ir_version = 10
onnx.checker.check_model(model)

feeds = {"x": np.linspace(-1.0, 1.0, 8, dtype=np.float32).reshape(2, 4)}
expected = ReferenceEvaluator(model).run(None, feeds)[0]
session = ort.InferenceSession(model.SerializeToString(), providers=["TensorrtExecutionProvider"])
assert "TensorrtExecutionProvider" in session.get_providers(), session.get_providers()
np.testing.assert_allclose(session.run(None, feeds)[0], expected, rtol=1e-3, atol=1e-3)
print("ok a model runs on TensorRT")
