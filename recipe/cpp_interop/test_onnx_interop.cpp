// onnx, libprotobuf and onnxruntime in one process on the shared libraries.

#include <onnx/checker.h>
#include <onnx/onnx_pb.h>
#include <onnx/shape_inference/implementation.h>
#include <onnxruntime/core/session/onnxruntime_cxx_api.h>

#include <array>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>

#define CHECK(cond, msg)                       \
  if (!(cond)) {                               \
    std::cerr << "FAIL: " << msg << std::endl; \
    return 1;                                  \
  }

int main() {
  std::vector<float> w(12), b(4), x(6), expected(8);
  for (size_t i = 0; i < w.size(); ++i) w[i] = 0.25f * static_cast<float>(i) - 1.0f;
  for (size_t i = 0; i < b.size(); ++i) b[i] = 0.5f - 0.3f * static_cast<float>(i);
  for (size_t i = 0; i < x.size(); ++i) x[i] = 0.1f * static_cast<float>(i) - 0.2f;
  for (int r = 0; r < 2; ++r)
    for (int c = 0; c < 4; ++c) {
      float acc = b[c];
      for (int k = 0; k < 3; ++k) acc += x[r * 3 + k] * w[k * 4 + c];
      expected[r * 4 + c] = acc > 0 ? acc : 0;
    }

  onnx::ModelProto model;
  model.set_ir_version(onnx::IR_VERSION);
  auto* opset = model.add_opset_import();
  opset->set_domain("");
  opset->set_version(21);
  auto* graph = model.mutable_graph();
  graph->set_name("interop");

  auto declare = [](onnx::ValueInfoProto* info, const char* name, std::vector<int64_t> dims) {
    info->set_name(name);
    auto* tt = info->mutable_type()->mutable_tensor_type();
    tt->set_elem_type(onnx::TensorProto::FLOAT);
    for (auto d : dims) tt->mutable_shape()->add_dim()->set_dim_value(d);
  };
  auto initializer = [graph](const char* name, std::vector<int64_t> dims, const std::vector<float>& v) {
    auto* t = graph->add_initializer();
    t->set_name(name);
    t->set_data_type(onnx::TensorProto::FLOAT);
    for (auto d : dims) t->add_dims(d);
    t->set_raw_data(std::string(reinterpret_cast<const char*>(v.data()), v.size() * sizeof(float)));
  };
  auto node = [graph](const char* op, std::vector<const char*> inputs, const char* output) {
    auto* n = graph->add_node();
    n->set_op_type(op);
    for (auto in : inputs) n->add_input(in);
    n->add_output(output);
  };

  declare(graph->add_input(), "x", {2, 3});
  declare(graph->add_output(), "y", {2, 4});
  initializer("w", {3, 4}, w);
  initializer("b", {4}, b);
  node("MatMul", {"x", "w"}, "xw");
  node("Add", {"xw", "b"}, "z");
  node("Relu", {"z"}, "y");

  std::string bytes;
  try {
    onnx::checker::check_model(model);
    onnx::shape_inference::InferShapes(model);
    CHECK(model.SerializeToString(&bytes), "SerializeToString");
  } catch (const std::exception& e) {
    CHECK(false, std::string("onnx before onnxruntime: ") + e.what());
  }

  for (int round = 0; round < 2; ++round) {
    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "interop");
    Ort::SessionOptions options;
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    Ort::Session session(env, bytes.data(), bytes.size(), options);
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    std::array<int64_t, 2> shape{2, 3};
    auto input = Ort::Value::CreateTensor<float>(memory, x.data(), x.size(), shape.data(), shape.size());
    const char* inputs[] = {"x"};
    const char* outputs[] = {"y"};
    auto result = session.Run(Ort::RunOptions{nullptr}, inputs, &input, 1, outputs, 1);
    const float* y = result.front().GetTensorData<float>();
    for (size_t i = 0; i < expected.size(); ++i)
      CHECK(std::fabs(y[i] - expected[i]) < 1e-5f, "round " << round << " output " << i);
    try {
      onnx::ModelProto reparsed;
      CHECK(reparsed.ParseFromString(bytes), "ParseFromString");
      onnx::checker::check_model(reparsed);
      onnx::shape_inference::InferShapes(reparsed);
    } catch (const std::exception& e) {
      CHECK(false, std::string("onnx after onnxruntime: ") + e.what());
    }
  }

  std::cout << "ok onnx + libprotobuf + onnxruntime interop" << std::endl;
  return 0;
}
