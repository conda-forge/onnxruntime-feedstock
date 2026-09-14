"""Runtime tests for onnxruntime linked against the shared conda-forge libraries.

onnxruntime used to statically link private copies of onnx, protobuf, abseil,
re2 and flatbuffers. With the shared libraries, failures can hide until
runtime: duplicate protobuf descriptor or ONNX schema registration when onnx
and onnxruntime share a process, symbols missing from libonnx, flatbuffers
headers that no longer match the runtime, or execution providers that fail to
load. Every model is checked against onnx's pure-Python ReferenceEvaluator.

Environment variables:
  ONNXRUNTIME_TEST_REQUIRE_CUDA=1  fail unless CUDAExecutionProvider runs the
                                   models on a GPU (for machines with one).
"""

# onnx.reference is imported only after onnxruntime, on purpose: importing
# onnxruntime registers its contrib schemas into the ONNX schema registry that
# the shared libonnx exposes to onnx's Python API as well.

import ctypes
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper

RNG = np.random.default_rng(0)
OPSET = helper.make_operatorsetid("", 21)
FAILURES = []


def check(name, fn):
    try:
        fn()
    except Exception as e:  # noqa: BLE001 - report every failure, then exit non-zero
        FAILURES.append(name)
        print(f"FAIL {name}: {type(e).__name__}: {e}", flush=True)
    else:
        print(f"PASS {name}", flush=True)


def make_model(nodes, inputs, outputs, initializers=(), opsets=(OPSET,), functions=()):
    graph = helper.make_graph(nodes, "g", inputs, outputs, initializer=list(initializers))
    model = helper.make_model(graph, opset_imports=list(opsets), functions=list(functions))
    onnx.checker.check_model(model, full_check=True)
    return model


def tensor(name, shape, dtype=TensorProto.FLOAT):
    return helper.make_tensor_value_info(name, dtype, shape)


def weight(name, *shape):
    # from_array stores raw_data, which onnxruntime parses through libonnx.
    return numpy_helper.from_array(RNG.standard_normal(shape).astype(np.float32), name)


def mlp():
    return make_model(
        [
            helper.make_node("MatMul", ["x", "w1"], ["h1"]),
            helper.make_node("Add", ["h1", "b1"], ["h2"]),
            helper.make_node("Relu", ["h2"], ["h3"]),
            helper.make_node("MatMul", ["h3", "w2"], ["h4"]),
            helper.make_node("Softmax", ["h4"], ["y"], axis=-1),
        ],
        [tensor("x", [4, 8])],
        [tensor("y", [4, 3])],
        [weight("w1", 8, 16), weight("b1", 16), weight("w2", 16, 3)],
    )


def cnn():
    bn_var = numpy_helper.from_array(RNG.uniform(0.5, 1.5, 4).astype(np.float32), "bn_var")
    return make_model(
        [
            helper.make_node("Conv", ["x", "conv_w", "conv_b"], ["c"], pads=[1, 1, 1, 1]),
            helper.make_node("BatchNormalization", ["c", "bn_s", "bn_b", "bn_m", "bn_var"], ["n"]),
            helper.make_node("Relu", ["n"], ["r"]),
            helper.make_node("MaxPool", ["r"], ["p"], kernel_shape=[2, 2], strides=[2, 2]),
            helper.make_node("GlobalAveragePool", ["p"], ["g"]),
            helper.make_node("Flatten", ["g"], ["f"]),
            helper.make_node("Gemm", ["f", "fc_w", "fc_b"], ["y"]),
        ],
        [tensor("x", [2, 3, 8, 8])],
        [tensor("y", [2, 5])],
        [
            weight("conv_w", 4, 3, 3, 3),
            weight("conv_b", 4),
            weight("bn_s", 4),
            weight("bn_b", 4),
            weight("bn_m", 4),
            bn_var,
            weight("fc_w", 4, 5),
            weight("fc_b", 5),
        ],
    )


def onnx_function_op():
    # Mish is defined in ONNX as a function; onnxruntime expands the body when it
    # has no kernel, which goes through libonnx's FunctionBuilder.
    return make_model([helper.make_node("Mish", ["x"], ["y"])], [tensor("x", [3, 5])], [tensor("y", [3, 5])])


def model_local_function():
    domain = "local.test"
    fn = helper.make_function(
        domain,
        "ScaledTanh",
        ["x"],
        ["y"],
        [
            helper.make_node("Constant", [], ["alpha"], value_float=1.7),
            helper.make_node("Tanh", ["x"], ["t"]),
            helper.make_node("Mul", ["t", "alpha"], ["y"]),
        ],
        [OPSET],
    )
    return make_model(
        [helper.make_node("ScaledTanh", ["x"], ["y"], domain=domain)],
        [tensor("x", [2, 6])],
        [tensor("y", [2, 6])],
        opsets=(OPSET, helper.make_operatorsetid(domain, 1)),
        functions=(fn,),
    )


def onnx_ml_ops():
    return make_model(
        [
            helper.make_node("Scaler", ["x"], ["s"], domain="ai.onnx.ml", offset=[0.5] * 4, scale=[2.0] * 4),
            helper.make_node(
                "LinearRegressor",
                ["s"],
                ["y"],
                domain="ai.onnx.ml",
                coefficients=RNG.standard_normal(8).astype(np.float32).tolist(),
                intercepts=[0.25, -0.5],
                targets=2,
            ),
        ],
        [tensor("x", [5, 4])],
        [tensor("y", [5, 2])],
        opsets=(OPSET, helper.make_operatorsetid("ai.onnx.ml", 3)),
    )


def transformer_block():
    # LayerNormalization plus the Gelu and attention-score patterns that
    # ORT_ENABLE_ALL fuses into com.microsoft ops through the contrib schemas.
    d = 16
    sqrt2 = numpy_helper.from_array(np.array(np.sqrt(2.0), dtype=np.float32), "sqrt2")
    one = numpy_helper.from_array(np.array(1.0, dtype=np.float32), "one")
    half = numpy_helper.from_array(np.array(0.5, dtype=np.float32), "half")
    scale = numpy_helper.from_array(np.array(1.0 / np.sqrt(d), dtype=np.float32), "scale")
    return make_model(
        [
            helper.make_node("LayerNormalization", ["x", "ln_s", "ln_b"], ["ln"], axis=-1),
            helper.make_node("MatMul", ["ln", "wq"], ["q"]),
            helper.make_node("MatMul", ["ln", "wk"], ["k"]),
            helper.make_node("Transpose", ["k"], ["kt"], perm=[0, 2, 1]),
            helper.make_node("MatMul", ["q", "kt"], ["qk"]),
            helper.make_node("Mul", ["qk", "scale"], ["qks"]),
            helper.make_node("Softmax", ["qks"], ["attn"], axis=-1),
            helper.make_node("MatMul", ["attn", "ln"], ["ctx"]),
            helper.make_node("MatMul", ["ctx", "w_ff"], ["ff"]),
            helper.make_node("Add", ["ff", "b_ff"], ["ffb"]),
            helper.make_node("Div", ["ffb", "sqrt2"], ["gd"]),
            helper.make_node("Erf", ["gd"], ["ge"]),
            helper.make_node("Add", ["ge", "one"], ["ga"]),
            helper.make_node("Mul", ["ffb", "ga"], ["gm"]),
            helper.make_node("Mul", ["gm", "half"], ["y"]),
        ],
        [tensor("x", [2, 7, d])],
        [tensor("y", [2, 7, d])],
        [
            weight("ln_s", d),
            weight("ln_b", d),
            weight("wq", d, d),
            weight("wk", d, d),
            weight("w_ff", d, d),
            weight("b_ff", d),
            sqrt2,
            one,
            half,
            scale,
        ],
    )


MODELS = {
    "mlp": mlp,
    "cnn": cnn,
    "onnx_function_op": onnx_function_op,
    "model_local_function": model_local_function,
    "onnx_ml_ops": onnx_ml_ops,
    "transformer_block": transformer_block,
}


def feeds_for(model):
    feeds = {}
    for inp in model.graph.input:
        shape = [d.dim_value for d in inp.type.tensor_type.shape.dim]
        feeds[inp.name] = RNG.standard_normal(shape).astype(np.float32)
    return feeds


def assert_close(actual, expected, atol, what):
    for a, e in zip(actual, expected):
        np.testing.assert_allclose(a, e, rtol=1e-4, atol=atol, err_msg=what)


def run_session(model_or_path, feeds, providers=("CPUExecutionProvider",), options=None):
    options = options or ort.SessionOptions()
    source = model_or_path if isinstance(model_or_path, str) else model_or_path.SerializeToString()
    session = ort.InferenceSession(source, options, providers=list(providers))
    return session, session.run(None, feeds)


def import_reference_evaluator():
    global ReferenceEvaluator
    from onnx.reference import ReferenceEvaluator


def test_import_order():
    # Fresh interpreters, so each order is the first registration in its process.
    snippet = (
        "import numpy as np\n"
        "from onnx import helper, TensorProto\n"
        "g = helper.make_graph([helper.make_node('Relu', ['x'], ['y'])], 'g',"
        " [helper.make_tensor_value_info('x', TensorProto.FLOAT, [2])],"
        " [helper.make_tensor_value_info('y', TensorProto.FLOAT, [2])])\n"
        "m = helper.make_model(g, opset_imports=[helper.make_operatorsetid('', 21)])\n"
        "onnx.checker.check_model(m); onnx.shape_inference.infer_shapes(m)\n"
        "s = onnxruntime.InferenceSession(m.SerializeToString(), providers=['CPUExecutionProvider'])\n"
        "assert (s.run(None, {'x': np.array([-1, 2], np.float32)})[0] == [0, 2]).all()\n"
        "import onnx.reference\n"
        "assert (onnx.reference.ReferenceEvaluator(m).run(None, {'x': np.array([-1, 2], np.float32)})[0] == [0, 2]).all()\n"
    )
    for first, second in (("onnx", "onnxruntime"), ("onnxruntime", "onnx")):
        code = f"import {first}\nimport {second}\n{snippet}"
        proc = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
        output = proc.stdout + proc.stderr
        for marker in ("already exists in database", "already registered", "Duplicate", "duplicate schema"):
            assert marker not in output, f"import {first} then {second}: {marker!r} in output:\n{output}"
        assert proc.returncode == 0, f"import {first} then {second} exited {proc.returncode}:\n{output}"


def test_cpu_against_reference(name, build):
    model = build()
    feeds = feeds_for(model)
    expected = ReferenceEvaluator(model).run(None, feeds)
    for level in (ort.GraphOptimizationLevel.ORT_DISABLE_ALL, ort.GraphOptimizationLevel.ORT_ENABLE_ALL):
        options = ort.SessionOptions()
        options.graph_optimization_level = level
        _, actual = run_session(model, feeds, options=options)
        assert_close(actual, expected, 1e-4, f"{name} at {level}")


def test_contrib_fusion_and_protobuf_round_trip(tmpdir):
    model = transformer_block()
    feeds = feeds_for(model)
    expected = ReferenceEvaluator(model).run(None, feeds)

    optimized_path = os.path.join(tmpdir, "optimized.onnx")
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.optimized_model_filepath = optimized_path
    run_session(model, feeds, options=options)

    # onnxruntime serialized the graph with the shared protobuf; parse it back with onnx.
    optimized = onnx.load(optimized_path)
    domains = {node.domain for node in optimized.graph.node}
    assert "com.microsoft" in domains, f"no contrib fusion happened, node domains: {domains}"
    _, actual = run_session(optimized_path, feeds)
    assert_close(actual, expected, 1e-4, "optimized transformer block")

    # A standard-ops model optimized at the basic level stays checkable by onnx,
    # in the same process that already created onnxruntime sessions.
    basic_path = os.path.join(tmpdir, "basic.onnx")
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    options.optimized_model_filepath = basic_path
    run_session(cnn(), feeds_for(cnn()), options=options)
    basic = onnx.load(basic_path)
    onnx.checker.check_model(basic, full_check=True)
    inferred = onnx.shape_inference.infer_shapes(basic, strict_mode=True)
    assert inferred.graph.output[0].type.tensor_type.shape.dim[1].dim_value == 5


def test_ort_format(tmpdir):
    # The .ort format is flatbuffers, generated with conda-forge's flatc.
    model = cnn()
    feeds = feeds_for(model)
    expected = ReferenceEvaluator(model).run(None, feeds)
    ort_path = os.path.join(tmpdir, "model.ort")
    options = ort.SessionOptions()
    options.optimized_model_filepath = ort_path
    options.add_session_config_entry("session.save_model_format", "ORT")
    run_session(model, feeds, options=options)
    options = ort.SessionOptions()
    options.add_session_config_entry("session.load_model_format", "ORT")
    _, actual = run_session(ort_path, feeds, options=options)
    assert_close(actual, expected, 1e-4, "ORT format round trip")


def test_lora_adapter(tmpdir):
    # Adapters are flatbuffers too. y = x @ (w + a @ b); the adapter overrides a and b.
    d, r = 6, 2
    w = RNG.standard_normal((d, d)).astype(np.float32)
    zeros_a, zeros_b = np.zeros((d, r), np.float32), np.zeros((r, d), np.float32)
    a = RNG.standard_normal((d, r)).astype(np.float32)
    b = RNG.standard_normal((r, d)).astype(np.float32)
    model = make_model(
        [
            helper.make_node("MatMul", ["lora_a", "lora_b"], ["ab"]),
            helper.make_node("Add", ["w", "ab"], ["wab"]),
            helper.make_node("MatMul", ["x", "wab"], ["y"]),
        ],
        [tensor("x", [3, d]), tensor("lora_a", [d, r]), tensor("lora_b", [r, d])],
        [tensor("y", [3, d])],
        [
            numpy_helper.from_array(w, "w"),
            numpy_helper.from_array(zeros_a, "lora_a"),
            numpy_helper.from_array(zeros_b, "lora_b"),
        ],
    )
    x = RNG.standard_normal((3, d)).astype(np.float32)

    adapter_path = os.path.join(tmpdir, "model.onnx_adapter")
    writer = ort.AdapterFormat()
    writer.set_adapter_version(1)
    writer.set_model_version(1)
    writer.set_parameters(
        {
            "lora_a": ort.OrtValue.ortvalue_from_numpy_with_onnx_type(a, TensorProto.FLOAT),
            "lora_b": ort.OrtValue.ortvalue_from_numpy_with_onnx_type(b, TensorProto.FLOAT),
        }
    )
    writer.export_adapter(adapter_path)
    read_back = ort.AdapterFormat.read_adapter(adapter_path).get_parameters()
    np.testing.assert_array_equal(read_back["lora_a"].numpy(), a)

    session = ort.InferenceSession(model.SerializeToString(), providers=["CPUExecutionProvider"])
    base = session.run(None, {"x": x})[0]
    np.testing.assert_allclose(base, x @ w, rtol=1e-5, atol=1e-5)
    adapter = ort.LoraAdapter()
    adapter.Load(adapter_path)
    run_options = ort.RunOptions()
    run_options.add_active_adapter(adapter)
    adapted = session.run(None, {"x": x}, run_options)[0]
    np.testing.assert_allclose(adapted, x @ (w + a @ b), rtol=1e-4, atol=1e-4)


def providers_used(session):
    # Profiling records which execution provider ran each node.
    with open(session.end_profiling()) as f:
        events = json.load(f)
    return {e["args"]["provider"] for e in events if e.get("cat") == "Node" and "provider" in e.get("args", {})}


def strict_session_options(tmpdir):
    options = ort.SessionOptions()
    options.add_session_config_entry("session.disable_cpu_ep_fallback", "1")
    options.enable_profiling = True
    options.profile_file_prefix = os.path.join(tmpdir, "profile")
    return options


def test_coreml(tmpdir):
    configs = [
        ({"ModelFormat": "MLProgram", "MLComputeUnits": "CPUOnly"}, 1e-4),
        ({"ModelFormat": "NeuralNetwork", "MLComputeUnits": "CPUOnly"}, 1e-4),
        # Whatever accelerators the machine has; float16 on the Neural Engine.
        ({"ModelFormat": "MLProgram", "MLComputeUnits": "ALL"}, 5e-3),
    ]
    model = mlp()
    feeds = feeds_for(model)
    expected = ReferenceEvaluator(model).run(None, feeds)
    for provider_options, atol in configs:
        session, actual = run_session(
            model,
            feeds,
            providers=[("CoreMLExecutionProvider", provider_options)],
            options=strict_session_options(tmpdir),
        )
        assert_close(actual, expected, atol, f"CoreML {provider_options}")
        used = providers_used(session)
        assert used == {"CoreMLExecutionProvider"}, f"CoreML {provider_options} ran nodes on {used}"


def capi_library(stem):
    capi = os.path.join(os.path.dirname(ort.__file__), "capi")
    names = [f for f in os.listdir(capi) if f.startswith(stem) and f.endswith((".so", ".dll", ".dylib"))]
    assert names, f"{stem} not found in {capi}: {os.listdir(capi)}"
    return os.path.join(capi, names[0])


def test_cuda_provider_library_loads():
    # Resolve every symbol of the CUDA provider now instead of when a session
    # first asks for it, without needing a GPU.
    if sys.platform == "win32":
        os.add_dll_directory(os.path.join(sys.prefix, "Library", "bin"))
        os.add_dll_directory(os.path.dirname(capi_library("onnxruntime_providers_shared")))
        ctypes.WinDLL(capi_library("onnxruntime_providers_shared"))
        ctypes.WinDLL(capi_library("onnxruntime_providers_cuda"))
        return
    mode = os.RTLD_NOW | os.RTLD_GLOBAL
    ctypes.CDLL(capi_library("libonnxruntime_providers_shared"), mode=mode)
    ctypes.CDLL(capi_library("libonnxruntime_providers_cuda"), mode=mode)


def nvidia_driver_present():
    # libcuda comes from the system NVIDIA driver, never from conda. The CUDA
    # provider links it, so without a driver it cannot be loaded at all.
    if sys.platform == "win32":
        return True
    try:
        ctypes.CDLL("libcuda.so.1")
    except OSError:
        return False
    return True


def test_cuda_on_gpu(tmpdir):
    for name, build in (("mlp", mlp), ("cnn", cnn), ("transformer_block", transformer_block)):
        model = build()
        feeds = feeds_for(model)
        expected = ReferenceEvaluator(model).run(None, feeds)
        options = strict_session_options(tmpdir)
        if name == "transformer_block":
            # Shape bookkeeping for the fused attention may legitimately stay on CPU.
            options = ort.SessionOptions()
            options.enable_profiling = True
            options.profile_file_prefix = os.path.join(tmpdir, "profile")
            options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        # TF32 matmuls on Ampere and newer GPUs differ from float32 by ~1e-2 in
        # attention; turn it off to compare the kernels against the reference.
        providers = [("CUDAExecutionProvider", {"use_tf32": "0"})]
        session, actual = run_session(model, feeds, providers=providers, options=options)
        assert_close(actual, expected, 1e-4, f"CUDA {name}")
        used = providers_used(session)
        assert "CUDAExecutionProvider" in used, f"CUDA {name} ran nodes on {used}"


def main():
    available = ort.get_available_providers()
    print("onnx", onnx.__version__, "onnxruntime", ort.__version__, "providers", available, flush=True)
    assert "CPUExecutionProvider" in available

    with tempfile.TemporaryDirectory() as tmpdir:
        check("import order onnx/onnxruntime", test_import_order)
        check("onnx.reference after onnxruntime registered its schemas", import_reference_evaluator)
        if "ReferenceEvaluator" not in globals():
            print(f"{len(FAILURES)} failed, cannot compare against the reference: {FAILURES}")
            sys.exit(1)
        for name, build in MODELS.items():
            check(f"CPU vs reference: {name}", lambda name=name, build=build: test_cpu_against_reference(name, build))
        check("contrib fusion + protobuf round trip", lambda: test_contrib_fusion_and_protobuf_round_trip(tmpdir))
        check("ORT format (flatbuffers)", lambda: test_ort_format(tmpdir))
        check("LoRA adapter (flatbuffers)", lambda: test_lora_adapter(tmpdir))

        if sys.platform == "darwin" and os.uname().machine == "arm64":
            assert "CoreMLExecutionProvider" in available, available
            check("CoreML execution provider", lambda: test_coreml(tmpdir))

        if "CUDAExecutionProvider" in available and not nvidia_driver_present():
            print("SKIP CUDA provider library loads: no NVIDIA driver (libcuda.so.1) on this machine")
            if os.environ.get("ONNXRUNTIME_TEST_REQUIRE_CUDA") == "1":
                FAILURES.append("CUDA required but no NVIDIA driver is present")
        elif "CUDAExecutionProvider" in available:
            check("CUDA provider library loads", test_cuda_provider_library_loads)
            if os.environ.get("ONNXRUNTIME_TEST_REQUIRE_CUDA") == "1":
                check("CUDA execution provider on GPU", lambda: test_cuda_on_gpu(tmpdir))
            else:
                print("SKIP CUDA execution on GPU: set ONNXRUNTIME_TEST_REQUIRE_CUDA=1 on a machine with a GPU")
        elif os.environ.get("ONNXRUNTIME_TEST_REQUIRE_CUDA") == "1":
            FAILURES.append("CUDA required but CUDAExecutionProvider is not available")

    if FAILURES:
        print(f"{len(FAILURES)} failed: {FAILURES}")
        sys.exit(1)
    print("all runtime tests passed")


if __name__ == "__main__":
    main()
