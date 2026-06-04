"""Runtime smoke test for the onnxruntime conda package.

This exercises the parts that the unvendored build most needs to get right:

* ``onnx`` and ``onnxruntime`` are imported into the *same* process. With the
  unvendored libonnx, onnxruntime links the shared ``libonnx`` and relies on
  ONNX's own static schema registration (IsOnnxStaticRegistrationDisabled()
  guard, upstream since onnxruntime 1.30.0). If that wiring is
  wrong this import pair aborts with duplicate ONNX schema / protobuf
  descriptor-pool registration errors before a single op runs.
* A tiny model built with ``onnx`` is executed by onnxruntime on the
  ``CPUExecutionProvider`` -- available on every CI runner -- and the result is
  checked against numpy. This proves the linked libonnx can actually parse a
  model and that inference works end to end.
"""

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper

print("onnx", onnx.__version__, "/ onnxruntime", ort.__version__)
print("providers:", ort.get_available_providers())
assert "CPUExecutionProvider" in ort.get_available_providers()

# y = relu(a @ b) + c -- a couple of standard ops across a small graph.
a = helper.make_tensor_value_info("a", TensorProto.FLOAT, [2, 3])
b = helper.make_tensor_value_info("b", TensorProto.FLOAT, [3, 4])
c = helper.make_tensor_value_info("c", TensorProto.FLOAT, [2, 4])
y = helper.make_tensor_value_info("y", TensorProto.FLOAT, [2, 4])
graph = helper.make_graph(
    [
        helper.make_node("MatMul", ["a", "b"], ["ab"]),
        helper.make_node("Relu", ["ab"], ["r"]),
        helper.make_node("Add", ["r", "c"], ["y"]),
    ],
    "matmul_relu_add",
    [a, b, c],
    [y],
)
model = helper.make_model(graph, opset_imports=[helper.make_operatorsetid("", 21)])
onnx.checker.check_model(model)

sess = ort.InferenceSession(
    model.SerializeToString(), providers=["CPUExecutionProvider"]
)
assert sess.get_providers() == ["CPUExecutionProvider"], sess.get_providers()

na = np.random.rand(2, 3).astype(np.float32)
nb = np.random.rand(3, 4).astype(np.float32)
nc = np.random.rand(2, 4).astype(np.float32)
(out,) = sess.run(["y"], {"a": na, "b": nb, "c": nc})

expected = np.maximum(na @ nb, 0.0) + nc
np.testing.assert_allclose(out, expected, rtol=1e-5, atol=1e-5)
print("onnxruntime CPU inference OK, output shape", out.shape)
