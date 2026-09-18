"""TEMPORARY: make conda-forge's abseil headers parse under nvcc 13.4 on Windows.

absl/hash/internal/hash.h declares

    friend class MixingHashState::HashStateBase;

which names the injected base-class name through MixingHashState. On Windows
conda-forge's abseil defaults ABSL_DLL to __declspec(dllimport) (a conda-forge
addition to absl/base/config.h), so MixingHashState is a dllimport class, and
the host code nvcc 13.4 generates makes MSVC reject that declaration:

    absl/hash/internal/hash.h(1428): error C3856: 'HashStateBase': symbol is
    not a class template

nvcc 13.0 accepted it, and onnxruntime's vendored abseil is not dllimport, so
only the unvendored Windows CUDA 13.4 build is affected. Name the base class
template specialization directly instead, which is equivalent. Remove once
this is fixed in the libabseil package.
"""

import pathlib
import sys

header = pathlib.Path(sys.argv[1])
old = "  friend class MixingHashState::HashStateBase;"
new = "  friend class HashStateBase<MixingHashState>;"
text = header.read_text()
if new in text:
    print(f"{header}: already patched")
elif old in text:
    header.write_text(text.replace(old, new, 1))
    print(f"{header}: replaced the qualified friend declaration")
else:
    sys.exit(f"{header}: expected declaration not found; remove this workaround")
