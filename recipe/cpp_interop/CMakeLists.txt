cmake_minimum_required(VERSION 3.20)
project(onnxruntime_onnx_interop CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(onnxruntime CONFIG REQUIRED)
find_package(ONNX CONFIG REQUIRED)
find_package(Protobuf CONFIG REQUIRED)

add_executable(test_onnx_interop test_onnx_interop.cpp)
target_link_libraries(test_onnx_interop PRIVATE onnxruntime::onnxruntime ONNX::onnx ONNX::onnx_proto protobuf::libprotobuf)
