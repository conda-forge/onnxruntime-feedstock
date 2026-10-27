import collections
import glob
import os
import re
import subprocess
import sys

build_dir = sys.argv[1]

sym_re = re.compile(r"^[0-9A-F]{3,} [0-9A-F]{8} (SECT[0-9A-F]+|UNDEF|ABS|DEBUG)\s+(\w+)\s*(\(\))?\s+(External|Static|WeakExternal|Label|Function|\w+)\s+\| (\S+)")
aux_re = re.compile(r"selection\s+(\d+)")


def symbols(path):
    out = subprocess.run(["dumpbin", "/nologo", "/SYMBOLS", path], capture_output=True, text=True, errors="replace").stdout
    comdat = set()
    last_section = None
    for line in out.splitlines():
        if "COFF SYMBOL TABLE" in line:
            comdat = set()
            last_section = None
            continue
        m = sym_re.match(line)
        if m:
            sect, _, fn, storage, name = m.groups()
            last_section = sect if storage == "Static" and name.startswith(".") else None
            if storage != "External":
                continue
            yield name, sect, bool(fn), sect in comdat
            continue
        a = aux_re.search(line)
        if a and last_section:
            comdat.add(last_section)


commands = subprocess.run(["ninja", "-C", build_dir, "-t", "commands", "onnxruntime_pybind11_state"], capture_output=True, text=True).stdout.splitlines()
link = [c for c in commands if "onnxruntime_pybind11_state.pyd" in c and ("link" in c.lower())][-1]
tokens = re.split(r"\s+", link)
edge = []
with open(os.path.join(build_dir, "build.ninja"), errors="replace") as f:
    inside = False
    for line in f:
        if line.startswith("build ") and "onnxruntime_pybind11_state.pyd" in line.split(":")[0]:
            inside = True
            continue
        if inside:
            if not line.startswith("  "):
                break
            edge.append(line.strip())
for line in edge:
    if line.startswith("LINK_LIBRARIES") or line.startswith("LINK_PATH"):
        print("SURVEY", line[:3000])
        tokens += re.split(r"\s+", line.split("=", 1)[1])
libs = []
for tok in tokens:
    tok = tok.strip('"')
    if tok.lower().endswith(".lib"):
        p = tok if os.path.isabs(tok) else os.path.join(build_dir, tok)
        if os.path.exists(p) and os.path.abspath(p).startswith(os.path.abspath(build_dir)) and p not in libs:
            libs.append(p)
if not libs:
    libs = [p for p in glob.glob(os.path.join(build_dir, "**", "*.lib"), recursive=True)
            if not re.search(r"test|gtest|gmock|benchmark|custom_op|onnxruntime_conda|providers_shared|pybind11_state", os.path.basename(p))]
print("SURVEY libs:", [os.path.relpath(p, build_dir) for p in libs])

defined = {}
kinds = collections.Counter()
for lib in libs:
    for name, sect, fn, is_comdat in symbols(lib):
        if sect.startswith("SECT"):
            kinds[(fn, is_comdat)] += 1
            defined.setdefault(name, (fn, is_comdat, os.path.basename(lib)))
print("SURVEY defined externals in static libs (function, comdat) -> count:", dict(kinds), "unique:", len(defined))

objs = glob.glob(os.path.join(build_dir, "CMakeFiles", "onnxruntime_pybind11_state.dir", "**", "*.obj"), recursive=True)
undef = set()
pydefined = set()
for o in objs:
    for name, sect, fn, is_comdat in symbols(o):
        if sect == "UNDEF":
            undef.add(name)
        elif sect.startswith("SECT"):
            pydefined.add(name)
undef -= pydefined
needed = {n: defined[n] for n in undef if n in defined}
c = collections.Counter((fn, cd) for fn, cd, _ in needed.values())
print("SURVEY pybind objs:", len(objs), "undef:", len(undef), "resolved by static libs:", len(needed), "(function, comdat) -> count:", dict(c))
for n, (fn, cd, lib) in sorted(needed.items()):
    if not fn and not cd:
        und = subprocess.run(["undname", n], capture_output=True, text=True).stdout.strip().splitlines()
        print("SURVEY data:", lib, n, und[-1] if und else "")
for n, (fn, cd, lib) in sorted(needed.items())[:4000]:
    print("SURVEY need:", "F" if fn else "D", "C" if cd else "-", lib, n)
