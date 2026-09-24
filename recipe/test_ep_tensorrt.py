"""Tests for the TensorRT execution provider package.

The EP is an in-tree provider bridge: libonnxruntime dlopens
libonnxruntime_providers_tensorrt.so from the directory of the loaded
libonnxruntime, so the library has to sit in onnxruntime/capi and its own
NEEDED entries (libnvinfer, libnvonnxparser, libcudart) have to resolve.
None of that shows up in an import check.

What runs depends on the machine:

  * always -- the library is where onnxruntime will look for it, every symbol
    resolves, and TensorrtExecutionProvider is compiled into the core;
  * with an NVIDIA driver and GPU -- a model actually runs through TensorRT and
    the result is compared against onnx's reference evaluator, and the session
    is asked which provider ran the nodes.

Environment variables:
  ONNXRUNTIME_TEST_REQUIRE_TENSORRT=1  fail instead of skipping when no GPU is
                                       usable, for machines that have one.
"""

import ctypes
import os
import sys

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper
from onnx.reference import ReferenceEvaluator

FAILURES = []
REQUIRE_GPU = os.environ.get("ONNXRUNTIME_TEST_REQUIRE_TENSORRT") == "1"
EP = "TensorrtExecutionProvider"


def check(name, fn):
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 - report every failure, not just the first
        FAILURES.append(f"{name}: {type(exc).__name__}: {exc}")
        print(f"FAIL {name}: {type(exc).__name__}: {exc}")
    else:
        print(f"ok   {name}")


def capi_dir():
    return os.path.join(os.path.dirname(ort.__file__), "capi")


def ep_library():
    path = os.path.join(capi_dir(), "libonnxruntime_providers_tensorrt.so")
    assert os.path.exists(path), f"{path} missing; capi holds {sorted(os.listdir(capi_dir()))}"
    return path


def test_library_is_where_onnxruntime_looks():
    # Not just "a file exists somewhere": onnxruntime resolves the provider
    # library relative to the loaded libonnxruntime, so capi is the only
    # directory that works for the python package.
    ep_library()
    assert any(
        f.startswith("libonnxruntime.so") for f in os.listdir(capi_dir())
    ), f"libonnxruntime is not in {capi_dir()}, so the EP would not be found there"


def test_library_symbols_resolve():
    # Resolve everything now rather than when a session first asks for the EP,
    # which turns a missing libnvinfer into a clear failure here instead of an
    # opaque one later. Needs no GPU.
    mode = os.RTLD_NOW | os.RTLD_GLOBAL
    ctypes.CDLL(os.path.join(capi_dir(), "libonnxruntime_providers_shared.so"), mode=mode)
    ctypes.CDLL(ep_library(), mode=mode)


def test_provider_is_compiled_in():
    available = ort.get_available_providers()
    assert EP in available, f"{EP} not in {available}"


def nvidia_driver_present():
    # libcuda comes from the system NVIDIA driver, never from conda.
    try:
        ctypes.CDLL("libcuda.so.1")
    except OSError:
        return False
    return True


def gpu_present():
    if not nvidia_driver_present():
        return False
    try:
        cuda = ctypes.CDLL("libcuda.so.1")
        if cuda.cuInit(0) != 0:
            return False
        count = ctypes.c_int(0)
        if cuda.cuDeviceGetCount(ctypes.byref(count)) != 0:
            return False
        return count.value > 0
    except OSError:
        return False


def matmul_model():
    weight = np.arange(12, dtype=np.float32).reshape(4, 3) / 12.0
    graph = helper.make_graph(
        [
            helper.make_node("MatMul", ["x", "w"], ["xw"]),
            helper.make_node("Relu", ["xw"], ["y"]),
        ],
        "trt_matmul",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [2, 4])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, [2, 3])],
        [helper.make_tensor("w", TensorProto.FLOAT, [4, 3], weight.flatten().tolist())],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_operatorsetid("", 21)])
    model.ir_version = 10
    onnx.checker.check_model(model)
    return model


def test_runs_on_tensorrt():
    model = matmul_model()
    feeds = {"x": np.linspace(-1.0, 1.0, 8, dtype=np.float32).reshape(2, 4)}
    expected = ReferenceEvaluator(model).run(None, feeds)[0]

    session = ort.InferenceSession(model.SerializeToString(), providers=[EP])
    used = session.get_providers()
    assert EP in used, f"session fell back to {used}"
    actual = session.run(None, feeds)[0]
    # TensorRT picks TF32 tactics on Ampere and newer, so the tolerance is
    # looser than float32 would need -- and a result this close is itself
    # evidence it really ran rather than silently producing zeros.
    np.testing.assert_allclose(actual, expected, rtol=1e-3, atol=1e-3)


def main():
    check("library is where onnxruntime looks", test_library_is_where_onnxruntime_looks)
    check("library symbols resolve", test_library_symbols_resolve)
    check("provider is compiled in", test_provider_is_compiled_in)

    if gpu_present():
        check("runs a model on TensorRT", test_runs_on_tensorrt)
    elif REQUIRE_GPU:
        FAILURES.append(
            "ONNXRUNTIME_TEST_REQUIRE_TENSORRT=1 but no usable NVIDIA GPU was found"
        )
        print("FAIL no usable NVIDIA GPU, and ONNXRUNTIME_TEST_REQUIRE_TENSORRT=1")
    else:
        print("skip runs a model on TensorRT (no usable NVIDIA GPU)")

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s):")
        for failure in FAILURES:
            print(f"  - {failure}")
        sys.exit(1)
    print("\nall TensorRT EP tests passed")


if __name__ == "__main__":
    main()
