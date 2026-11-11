#define ORT_API_MANUAL_INIT
#include <onnxruntime/core/session/onnxruntime_cxx_api.h>
// Mixing the source tree's and the flat layout must not redefine anything.
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <cstdlib>
#include <iostream>

int main() {
    Ort::InitApi();
    const auto providers = Ort::GetAvailableProviders();

    for (const auto& provider : providers) {
        std::cout << provider << '\n';
    }

    return EXIT_SUCCESS;
}

