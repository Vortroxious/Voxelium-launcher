#!/usr/bin/env python3
"""Writes the notices for the Rust crates in StikJIT's libidevice_ffi.a, for
scripts/collect-licenses.sh. Reads build/deps/idevice-licenses (from
scripts/fetch-idevice-licenses.sh): one folder per crate with its licence files
and its declared licence (.spdx). Identical licence texts are printed once,
followed by the crates they come from. A crate that ships no licence file gets
the standard text of the licence it declares, with its authors from Cargo.toml.

Usage: idevice-notices.py <idevice-licenses dir> <idevice-crates dir> <output file>
"""
import os
import re
import sys
import tarfile

MIT = """Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

BSD3 = """Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""


def authors(crates_dir, crate):
    with tarfile.open(os.path.join(crates_dir, crate + ".crate")) as t:
        toml = t.extractfile(f"{crate}/Cargo.toml").read().decode()
    m = re.search(r"^authors = \[(.*?)\]", toml, re.M | re.S)
    names = re.findall(r'"([^"]+)"', m.group(1)) if m else []
    names = [re.sub(r"\s*<[^>]*>", "", n) for n in names]
    return ", ".join(names) or f"the {crate.rsplit('-', 1)[0]} authors"


def main(lic_dir, crates_dir, out):
    crates = sorted(d for d in os.listdir(lic_dir) if os.path.isdir(os.path.join(lic_dir, d)))
    texts = {}  # licence text -> crates it comes from
    lines = []
    for crate in crates:
        folder = os.path.join(lic_dir, crate)
        spdx = open(os.path.join(folder, ".spdx")).read().strip() or "no licence declared"
        lines.append(f"  {crate}: {spdx}")
        files = sorted(f for f in os.listdir(folder) if not f.startswith("."))
        if not files:
            # The crate ships no licence file: use the declared licence's standard text.
            who = authors(crates_dir, crate)
            if "MIT" in spdx:
                files_text = [("MIT (declared; no licence file in the crate)", f"Copyright (c) {who}\n\n{MIT}")]
            elif "BSD-3-Clause" in spdx:
                files_text = [("BSD-3-Clause (declared; no licence file in the crate)", f"Copyright (c) {who}\n\n{BSD3}")]
            else:
                sys.exit(f"{crate}: no licence file and no standard text for {spdx}")
        else:
            files_text = [(f, open(os.path.join(folder, f), errors="replace").read()) for f in files]
        for name, text in files_text:
            texts.setdefault(text.strip(), []).append(f"{crate} ({name})")
    with open(out, "w") as f:
        f.write("Rust crates compiled into libidevice_ffi (crate: declared licence). Where a crate\n"
                "offers a choice, Voxelium uses it under any of the licences offered.\n\n")
        f.write("\n".join(lines) + "\n")
        f.write("\nLicence texts from the crates. Each text is printed once, followed by the crates\n"
                "(and files) it comes from.\n")
        for text, origins in texts.items():
            f.write("\n" + "-" * 80 + "\n")
            f.write(text + "\n\n")
            f.write("From: " + "; ".join(origins) + "\n")


if __name__ == "__main__":
    main(*sys.argv[1:4])
