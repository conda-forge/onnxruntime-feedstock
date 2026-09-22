// A C++ program that uses libonnx, libprotobuf and onnxruntime in one process.
//
// With onnx and protobuf unvendored, onnxruntime and this program share one
// copy of the onnx protobuf descriptors and the ONNX schema registry. Build a
// model with the onnx C++ API, check and shape-infer it, run it through
// onnxruntime (which registers its own contrib schemas into the same
// registry), then check it again and create a second environment.

#include <onnx/checker.h>
#include <onnx/defs/schema.h>
#include <onnx/onnx_pb.h>
#include <onnx/shape_inference/implementation.h>
#include <onnxruntime/core/session/onnxruntime_cxx_api.h>

#include <array>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

namespace {

constexpr int64_t kBatch = 2, kIn = 3, kOut = 4;

void Fail(const std::string& msg) {
  std::cerr << "FAIL: " << msg << std::endl;
  std::exit(EXIT_FAILURE);
}

void SetTensorType(onnx::ValueInfoProto* info, const std::string& name, std::vector<int64_t> dims) {
  info->set_name(name);
  auto* tensor_type = info->mutable_type()->mutable_tensor_type();
  tensor_type->set_elem_type(onnx::TensorProto::FLOAT);
  for (auto d : dims) tensor_type->mutable_shape()->add_dim()->set_dim_value(d);
}

void AddInitializer(onnx::GraphProto* graph, const std::string& name, std::vector<int64_t> dims,
                    const std::vector<float>& values) {
  auto* t = graph->add_initializer();
  t->set_name(name);
  t->set_data_type(onnx::TensorProto::FLOAT);
  for (auto d : dims) t->add_dims(d);
  // raw_data, like every exporter writes it.
  t->set_raw_data(std::string(reinterpret_cast<const char*>(values.data()), values.size() * sizeof(float)));
}

onnx::NodeProto* AddNode(onnx::GraphProto* graph, const std::string& op, std::vector<std::string> inputs,
                         const std::string& output) {
  auto* node = graph->add_node();
  node->set_op_type(op);
  for (auto& in : inputs) node->add_input(in);
  node->add_output(output);
  return node;
}

}  // namespace

int main() {
  std::vector<float> w(kIn * kOut), b(kOut), x(kBatch * kIn);
  for (size_t i = 0; i < w.size(); ++i) w[i] = 0.25f * static_cast<float>(i) - 1.0f;
  for (size_t i = 0; i < b.size(); ++i) b[i] = 0.5f - 0.3f * static_cast<float>(i);
  for (size_t i = 0; i < x.size(); ++i) x[i] = 0.1f * static_cast<float>(i) - 0.2f;

  // y = Relu(x @ w + b)
  onnx::ModelProto model;
  model.set_ir_version(onnx::IR_VERSION);
  model.set_producer_name("onnxruntime-feedstock interop test");
  auto* opset = model.add_opset_import();
  opset->set_domain("");
  opset->set_version(21);
  auto* graph = model.mutable_graph();
  graph->set_name("interop");
  SetTensorType(graph->add_input(), "x", {kBatch, kIn});
  SetTensorType(graph->add_output(), "y", {kBatch, kOut});
  AddInitializer(graph, "w", {kIn, kOut}, w);
  AddInitializer(graph, "b", {kOut}, b);
  AddNode(graph, "MatMul", {"x", "w"}, "xw");
  AddNode(graph, "Add", {"xw", "b"}, "z");
  AddNode(graph, "Relu", {"z"}, "y");

  if (onnx::OpSchemaRegistry::Schema("Relu", 21) == nullptr) Fail("ONNX schema registry has no Relu-21");
  try {
    onnx::checker::check_model(model);
    onnx::shape_inference::InferShapes(model);
  } catch (const std::exception& e) {
    Fail(std::string("onnx checker/shape inference before onnxruntime: ") + e.what());
  }
  bool inferred_z = false;
  for (const auto& vi : graph->value_info()) inferred_z |= vi.name() == "z";
  if (!inferred_z) Fail("onnx shape inference did not infer the intermediate value 'z'");

  std::string bytes;
  if (!model.SerializeToString(&bytes)) Fail("SerializeToString");

  std::vector<float> expected(kBatch * kOut);
  for (int64_t r = 0; r < kBatch; ++r)
    for (int64_t c = 0; c < kOut; ++c) {
      float acc = b[c];
      for (int64_t k = 0; k < kIn; ++k) acc += x[r * kIn + k] * w[k * kOut + c];
      expected[r * kOut + c] = acc > 0 ? acc : 0;
    }

  for (int round = 0; round < 2; ++round) {
    // A second Env re-runs onnxruntime's environment setup in this process.
    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "interop");
    Ort::SessionOptions options;
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    Ort::Session session(env, bytes.data(), bytes.size(), options);

    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::array<int64_t, 2> shape{kBatch, kIn};
    auto input = Ort::Value::CreateTensor<float>(memory, x.data(), x.size(), shape.data(), shape.size());
    const char* input_names[] = {"x"};
    const char* output_names[] = {"y"};
    auto outputs = session.Run(Ort::RunOptions{nullptr}, input_names, &input, 1, output_names, 1);
    const float* y = outputs.front().GetTensorData<float>();
    for (size_t i = 0; i < expected.size(); ++i)
      if (std::fabs(y[i] - expected[i]) > 1e-5f)
        Fail("round " + std::to_string(round) + " output " + std::to_string(i) + ": " + std::to_string(y[i]) +
             " != " + std::to_string(expected[i]));

    // onnx still works after onnxruntime registered its schemas into the shared registry.
    try {
      onnx::ModelProto reparsed;
      if (!reparsed.ParseFromString(bytes)) Fail("ParseFromString");
      onnx::checker::check_model(reparsed);
      onnx::shape_inference::InferShapes(reparsed);
    } catch (const std::exception& e) {
      Fail("onnx checker/shape inference after onnxruntime, round " + std::to_string(round) + ": " + e.what());
    }
  }

  std::cout << "onnx + protobuf + onnxruntime interop OK" << std::endl;
  return EXIT_SUCCESS;
}
