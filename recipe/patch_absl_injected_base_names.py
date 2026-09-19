"""TEMPORARY: make abseil's headers compile under nvcc 13.4 on Windows.

abseil names a base class through the derived class in several headers, e.g.

    friend class MixingHashState::HashStateBase;          # absl/hash
    using Base = typename flat_hash_map::raw_hash_map;    # absl/container

Both spellings rely on the injected-class-name of a dependent base. In the host
code NVCC 13.4 generates, MSVC does not resolve them and the CUDA translation
units of onnxruntime_providers_cuda fail with, depending on conformance mode:

    absl/hash/internal/hash.h(1428): error C3856: 'HashStateBase': symbol is
      not a class template
    absl/container/flat_hash_map.h(141): error C2248: cannot access private
      typedef declared in class 'raw_hash_map'
    absl/container/internal/raw_hash_map.h(51): error C2794: 'reference': is
      not a member of any direct or indirect base class

nvcc 13.0 compiles all of this, and the same constructs are in the abseil that
onnxruntime vendors, so this is an nvcc 13.4 regression rather than anything
specific to the conda-forge package. Name each base directly instead, which is
equivalent. Remove once nvcc or abseil fixes this.

Usage: patch_absl_injected_base_names.py <include-dir> [<include-dir> ...]
"""

import pathlib
import sys

# header -> list of (old, new) exact replacements
REPLACEMENTS = {
    "absl/hash/internal/hash.h": [
        (
            "  friend class MixingHashState::HashStateBase;",
            "  friend class HashStateBase<MixingHashState>;",
        ),
    ],
    "absl/hash/hash.h": [
        (
            "  friend class HashState::HashStateBase;",
            "  friend class hash_internal::HashStateBase<HashState>;",
        ),
    ],
    "absl/container/flat_hash_map.h": [
        (
            "  using Base = typename flat_hash_map::raw_hash_map;",
            "  using Base = typename absl::container_internal::InstantiateRawHashMap<\n"
            "      absl::container_internal::FlatHashMapPolicy<K, V>, Hash, Eq,\n"
            "      Allocator>::type;",
        ),
    ],
    "absl/container/flat_hash_set.h": [
        (
            "  using Base = typename flat_hash_set::raw_hash_set;",
            "  using Base = typename absl::container_internal::InstantiateRawHashSet<\n"
            "      absl::container_internal::FlatHashSetPolicy<T>, Hash, Eq,\n"
            "      Allocator>::type;",
        ),
    ],
    "absl/container/node_hash_map.h": [
        (
            "  using Base = typename node_hash_map::raw_hash_map;",
            "  using Base = typename absl::container_internal::InstantiateRawHashMap<\n"
            "      absl::container_internal::NodeHashMapPolicy<Key, Value>, Hash, Eq,\n"
            "      Alloc>::type;",
        ),
    ],
    "absl/container/node_hash_set.h": [
        (
            "  using Base = typename node_hash_set::raw_hash_set;",
            "  using Base = typename absl::container_internal::InstantiateRawHashSet<\n"
            "      absl::container_internal::NodeHashSetPolicy<T>, Hash, Eq,\n"
            "      Alloc>::type;",
        ),
    ],
}

patched = 0
missing = []
for include_dir in sys.argv[1:]:
    for relative, pairs in REPLACEMENTS.items():
        header = pathlib.Path(include_dir) / relative
        if not header.is_file():
            continue
        text = header.read_text()
        original = text
        for old, new in pairs:
            if new in text:
                continue
            if old not in text:
                missing.append(f"{header}: {old.strip()}")
                continue
            text = text.replace(old, new, 1)
        if text != original:
            header.write_text(text)
            patched += 1
            print(f"{header}: patched")

if missing:
    sys.exit("declarations not found (remove this workaround?):\n  " + "\n  ".join(missing))
print(f"patched {patched} abseil header(s)")
