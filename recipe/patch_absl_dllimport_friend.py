"""TEMPORARY: make conda-forge's abseil headers parse under nvcc 13.4 on Windows.

absl's hash headers befriend their CRTP base through the derived class:

    friend class MixingHashState::HashStateBase;   # absl/hash/internal/hash.h
    friend class HashState::HashStateBase;         # absl/hash/hash.h

On Windows conda-forge's abseil defaults ABSL_DLL to __declspec(dllimport)
(a conda-forge addition to absl/base/config.h), so those classes are dllimport
and MSVC rejects the declarations in the host code nvcc 13.4 generates:

    absl/hash/internal/hash.h(1428): error C3856: 'HashStateBase': symbol is
    not a class template

nvcc 13.0 accepted it, and onnxruntime's vendored abseil is not dllimport, so
only the unvendored Windows CUDA 13.4 build is affected. Name the base class
template specialization directly instead, which is equivalent. The sibling
`using Derived::HashStateBase::member;` declarations compile fine and are left
alone. Remove once this is fixed in the libabseil package.

Usage: patch_absl_dllimport_friend.py <include-dir> [<include-dir> ...]
Every existing header found under the given include directories is patched.
"""

import pathlib
import sys

REPLACEMENTS = {
    "absl/hash/internal/hash.h": (
        "  friend class MixingHashState::HashStateBase;",
        "  friend class HashStateBase<MixingHashState>;",
    ),
    "absl/hash/hash.h": (
        "  friend class HashState::HashStateBase;",
        "  friend class hash_internal::HashStateBase<HashState>;",
    ),
}

patched = 0
seen = 0
for include_dir in sys.argv[1:]:
    for relative, (old, new) in REPLACEMENTS.items():
        header = pathlib.Path(include_dir) / relative
        if not header.is_file():
            continue
        seen += 1
        text = header.read_text()
        if new in text:
            print(f"{header}: already patched")
            patched += 1
        elif old in text:
            header.write_text(text.replace(old, new, 1))
            print(f"{header}: replaced the qualified friend declaration")
            patched += 1
        else:
            sys.exit(f"{header}: expected declaration not found; remove this workaround")

if not seen:
    sys.exit(f"no abseil headers found under: {' '.join(sys.argv[1:])}")
print(f"patched {patched} abseil header(s)")
