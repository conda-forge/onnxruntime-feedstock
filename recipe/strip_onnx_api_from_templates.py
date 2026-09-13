"""TEMPORARY: make libonnx's onnx/defs/function.h usable from MSVC consumers.

libonnx on win-64 defines ONNX_API as __declspec(dllimport) for consumers,
but function.h marks member function templates defined in the header with
ONNX_API, which MSVC rejects (C2491: definition of dllimport function not
allowed). Strip ONNX_API from those templates in the host environment's copy
of the header. Remove once libonnx carries the fix.
"""

import pathlib
import re
import sys

header = pathlib.Path(sys.argv[1])
lines = header.read_text().splitlines(keepends=True)
changed = 0
for i in range(1, len(lines)):
    if lines[i - 1].lstrip().startswith("template") and re.match(r"\s*ONNX_API\s", lines[i]):
        lines[i] = re.sub(r"ONNX_API\s+", "", lines[i], count=1)
        changed += 1
header.write_text("".join(lines))
print(f"stripped ONNX_API from {changed} templates in {header}")
