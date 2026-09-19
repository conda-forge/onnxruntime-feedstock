"""TEMPORARY: make abseil's headers compile under nvcc 13.4 on Windows.

abseil names a base class through the derived class in several headers:

    friend class MixingHashState::HashStateBase;          # absl/hash
    using Base = typename flat_hash_map::raw_hash_map;    # absl/container

Both rely on the injected-class-name of a dependent base. In the host code
NVCC 13.4 generates, MSVC does not resolve them, and the CUDA translation units
of onnxruntime_providers_cuda fail with, depending on conformance mode:

    absl/hash/internal/hash.h(1428): error C3856: 'HashStateBase': symbol is
      not a class template
    absl/container/flat_hash_map.h(141): error C2248: cannot access private
      typedef declared in class 'raw_hash_map'

Name each base directly instead. For the containers that also means renaming
the class template's Hash/Eq parameters: raw_hash_map and raw_hash_set declare
private typedefs of those names, which hide the template parameters inside the
derived class body, so spelling the base type out would pick up the private
typedefs and fail with the same C2248. The parameters are not referenced
anywhere else inside these class bodies.

nvcc 13.0 compiles all of this, and the same constructs are in the abseil that
onnxruntime vendors, so this is an nvcc 13.4 regression rather than anything
specific to the conda-forge package. Remove once nvcc or abseil fixes it.

Usage: patch_absl_injected_base_names.py <include-dir> [<include-dir> ...]
"""

import pathlib
import sys

_CONTAINERS = {
    "absl/container/flat_hash_map.h": (
        """    class Hash =
        typename container_internal::FlatHashMapPolicy<K, V>::DefaultHash,
    class Eq = typename container_internal::FlatHashMapPolicy<K, V>::DefaultEq,
    class Allocator =
        typename container_internal::FlatHashMapPolicy<K, V>::DefaultAlloc>
class ABSL_ATTRIBUTE_OWNER flat_hash_map
    : public absl::container_internal::InstantiateRawHashMap<
          absl::container_internal::FlatHashMapPolicy<K, V>, Hash, Eq,
          Allocator>::type {
  using Base = typename flat_hash_map::raw_hash_map;
""",
        """    class AbslHashT =
        typename container_internal::FlatHashMapPolicy<K, V>::DefaultHash,
    class AbslEqT =
        typename container_internal::FlatHashMapPolicy<K, V>::DefaultEq,
    class Allocator =
        typename container_internal::FlatHashMapPolicy<K, V>::DefaultAlloc>
class ABSL_ATTRIBUTE_OWNER flat_hash_map
    : public absl::container_internal::InstantiateRawHashMap<
          absl::container_internal::FlatHashMapPolicy<K, V>, AbslHashT, AbslEqT,
          Allocator>::type {
  using Base = typename absl::container_internal::InstantiateRawHashMap<
      absl::container_internal::FlatHashMapPolicy<K, V>, AbslHashT, AbslEqT,
      Allocator>::type;
""",
    ),
    "absl/container/flat_hash_set.h": (
        """    class Hash = typename container_internal::FlatHashSetPolicy<T>::DefaultHash,
    class Eq = typename container_internal::FlatHashSetPolicy<T>::DefaultEq,
    class Allocator =
        typename container_internal::FlatHashSetPolicy<T>::DefaultAlloc>
class ABSL_ATTRIBUTE_OWNER flat_hash_set
    : public absl::container_internal::InstantiateRawHashSet<
          absl::container_internal::FlatHashSetPolicy<T>, Hash, Eq,
          Allocator>::type {
  using Base = typename flat_hash_set::raw_hash_set;
""",
        """    class AbslHashT =
        typename container_internal::FlatHashSetPolicy<T>::DefaultHash,
    class AbslEqT = typename container_internal::FlatHashSetPolicy<T>::DefaultEq,
    class Allocator =
        typename container_internal::FlatHashSetPolicy<T>::DefaultAlloc>
class ABSL_ATTRIBUTE_OWNER flat_hash_set
    : public absl::container_internal::InstantiateRawHashSet<
          absl::container_internal::FlatHashSetPolicy<T>, AbslHashT, AbslEqT,
          Allocator>::type {
  using Base = typename absl::container_internal::InstantiateRawHashSet<
      absl::container_internal::FlatHashSetPolicy<T>, AbslHashT, AbslEqT,
      Allocator>::type;
""",
    ),
    "absl/container/node_hash_map.h": (
        """        typename container_internal::NodeHashMapPolicy<Key, Value>::DefaultHash,
    class Eq =
        typename container_internal::NodeHashMapPolicy<Key, Value>::DefaultEq,
    class Alloc = typename container_internal::NodeHashMapPolicy<
        Key, Value>::DefaultAlloc>
class ABSL_ATTRIBUTE_OWNER node_hash_map
    : public absl::container_internal::InstantiateRawHashMap<
          absl::container_internal::NodeHashMapPolicy<Key, Value>, Hash, Eq,
          Alloc>::type {
  using Base = typename node_hash_map::raw_hash_map;
""",
        """        typename container_internal::NodeHashMapPolicy<Key, Value>::DefaultHash,
    class AbslEqT =
        typename container_internal::NodeHashMapPolicy<Key, Value>::DefaultEq,
    class Alloc = typename container_internal::NodeHashMapPolicy<
        Key, Value>::DefaultAlloc>
class ABSL_ATTRIBUTE_OWNER node_hash_map
    : public absl::container_internal::InstantiateRawHashMap<
          absl::container_internal::NodeHashMapPolicy<Key, Value>, AbslHashT,
          AbslEqT, Alloc>::type {
  using Base = typename absl::container_internal::InstantiateRawHashMap<
      absl::container_internal::NodeHashMapPolicy<Key, Value>, AbslHashT,
      AbslEqT, Alloc>::type;
""",
    ),
    "absl/container/node_hash_set.h": (
        """    class Hash = typename container_internal::NodeHashSetPolicy<T>::DefaultHash,
    class Eq = typename container_internal::NodeHashSetPolicy<T>::DefaultEq,
    class Alloc =
        typename container_internal::NodeHashSetPolicy<T>::DefaultAlloc>
class ABSL_ATTRIBUTE_OWNER node_hash_set
    : public absl::container_internal::InstantiateRawHashSet<
          absl::container_internal::NodeHashSetPolicy<T>, Hash, Eq,
          Alloc>::type {
  using Base = typename node_hash_set::raw_hash_set;
""",
        """    class AbslHashT =
        typename container_internal::NodeHashSetPolicy<T>::DefaultHash,
    class AbslEqT = typename container_internal::NodeHashSetPolicy<T>::DefaultEq,
    class Alloc =
        typename container_internal::NodeHashSetPolicy<T>::DefaultAlloc>
class ABSL_ATTRIBUTE_OWNER node_hash_set
    : public absl::container_internal::InstantiateRawHashSet<
          absl::container_internal::NodeHashSetPolicy<T>, AbslHashT, AbslEqT,
          Alloc>::type {
  using Base = typename absl::container_internal::InstantiateRawHashSet<
      absl::container_internal::NodeHashSetPolicy<T>, AbslHashT, AbslEqT,
      Alloc>::type;
""",
    ),
}

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
    **{header: [pair] for header, pair in _CONTAINERS.items()},
}

# node_hash_map declares its Hash parameter on the line above the block matched
# above, so rename it separately.
EXTRA = {
    "absl/container/node_hash_map.h": [
        ("    class Hash =\n", "    class AbslHashT =\n"),
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
        for old, new in list(EXTRA.get(relative, [])) + list(pairs):
            if new in text:
                continue
            if old not in text:
                missing.append(f"{header}: {old.strip().splitlines()[0]}")
                continue
            text = text.replace(old, new, 1)
        if text != original:
            header.write_text(text)
            patched += 1
            print(f"{header}: patched")

if missing:
    sys.exit("declarations not found (remove this workaround?):\n  " + "\n  ".join(missing))
print(f"patched {patched} abseil header(s)")
