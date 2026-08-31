#!/usr/bin/env python3
"""Build dist/wgq as a deterministic, exit-code-correct zipapp.

``python -m zipapp`` is deliberately not used, for three defects that all
matter to this artifact:

  * It packs whatever is under src/, including __pycache__/ left behind by
    a test run -- so the artifact's contents depended on what you happened
    to do before building it.
  * Its generated __main__ calls the entry point and DISCARDS the return
    value, so the zipapp exited 0 even when a command failed.  A tool whose
    whole design is "fail loudly" must not ship inside a wrapper that eats
    the failure.
  * It stores filesystem mtimes and directory-walk order, so two builds of
    the same tree hashed differently.  A deterministic archive is what lets
    anyone check a downloaded artifact against their own `make` instead of
    trusting whoever uploaded it.

Here: only *.py files, sorted paths, one fixed timestamp, no compression
(deflate output varies between zlib builds; the tree is tiny anyway), and a
__main__ that propagates the exit status.  Same tree in, same bytes out.

Standard library only, like everything else in this repository.
"""

import os
import sys
import zipfile

INTERPRETER = b"#!/usr/bin/env python3\n"
# Any fixed date after 1980 (the zip format's epoch) works; what matters is
# that it never changes between builds.
TIMESTAMP = (2020, 1, 1, 0, 0, 0)
MAIN_STUB = "import sys\n\nimport wgq.cli\n\nsys.exit(wgq.cli.main())\n"


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <srcdir> <output>", file=sys.stderr)
        return 2
    src, out = sys.argv[1], sys.argv[2]

    sources = []
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
        for filename in filenames:
            if filename.endswith(".py"):
                full = os.path.join(dirpath, filename)
                arcname = os.path.relpath(full, src).replace(os.sep, "/")
                sources.append((arcname, full))
    if not sources:
        print(f"mkzipapp: no python sources under {src}", file=sys.stderr)
        return 1
    sources.sort()

    tmp = out + ".tmp"
    with open(tmp, "wb") as raw:
        raw.write(INTERPRETER)
        with zipfile.ZipFile(raw, "w", compression=zipfile.ZIP_STORED) as archive:
            for arcname, full in sources:
                info = zipfile.ZipInfo(arcname, date_time=TIMESTAMP)
                info.external_attr = 0o644 << 16
                with open(full, "rb") as handle:
                    archive.writestr(info, handle.read())
            stub = zipfile.ZipInfo("__main__.py", date_time=TIMESTAMP)
            stub.external_attr = 0o644 << 16
            archive.writestr(stub, MAIN_STUB)
    os.chmod(tmp, 0o755)
    os.replace(tmp, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
