"""Runs the upload plan of .github/workflows/native-prebuilt.yml (the Python between <<'PLAN' and PLAN in the publish
job) on made-up releases: what it keeps, uploads, replaces and refuses.

Usage: python3 -I .github/scripts/native-prebuilt-plan-test.py
"""

import hashlib
import pathlib
import subprocess
import sys
import tempfile
import textwrap

WORKFLOW = pathlib.Path(__file__).resolve().parent.parent / "workflows" / "native-prebuilt.yml"
TARGETS = {"linux-x86_64": ".so", "linux-arm64": ".so", "macos-x86_64": ".dylib", "macos-arm64": ".dylib",
           "windows-x86_64": ".dll"}
SOURCE, API = "0123456789abcdef", "1.4"
URL = "https://example.invalid/native-{source}/lib{name}-{api}-{target}{ext}"


def plan_script() -> str:
    lines = WORKFLOW.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.endswith("<<'PLAN'"))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "PLAN")
    return textwrap.dedent("\n".join(lines[start + 1:end])) + "\n"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def run(script, *, row_api=API, pins=None, on_release=None, may_replace="no"):
    """pins: target -> bytes the row pins; on_release: target -> bytes the release holds."""
    pins, on_release = pins or {}, on_release or {}
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        built, held = tmp / "built", tmp / "held"
        built.mkdir()
        held.mkdir()
        names = {t: f"libm-{API}-{t}{ext}" for t, ext in TARGETS.items()}
        for target, name in names.items():
            (built / name).write_bytes(f"fresh {target}".encode())
        for target, data in on_release.items():
            (held / names[target]).write_bytes(data)
        (tmp / "assets").write_text("".join(names[t] + "\n" for t in on_release))
        manifest = '[native.m]\nbuild = { sources = ["native/m.c"] }\n'
        if pins:
            table = ", ".join(f'{t} = "{digest(data)}"' for t, data in pins.items())
            manifest += f'prebuilt = {{ url = "{URL}", source = "{SOURCE}", api = "{row_api}", sha256 = {{ {table} }} }}\n'
        (tmp / "agentica.toml").write_text(manifest)
        args = [tmp / "agentica.toml", "m", SOURCE, API, may_replace, tmp / "assets", held, built, URL, tmp / "plan"]
        done = subprocess.run([sys.executable, "-I", "-", *map(str, args)], input=script, text=True,
                              capture_output=True)
        plan = (tmp / "plan").read_text().split("\n") if (tmp / "plan").exists() else None
        return done, [line for line in plan or [] if line], names


def main() -> None:
    script = plan_script()
    fresh = {t: f"fresh {t}".encode() for t in TARGETS}
    old = {t: f"old {t}".encode() for t in TARGETS}

    # Nothing on the release and no row: every file is uploaded, the row is the fresh build.
    done, plan, names = run(script)
    assert done.returncode == 0, done.stderr
    assert plan == [f"upload {names[t]}" for t in TARGETS], plan
    assert all(digest(fresh[t]) in done.stdout for t in TARGETS), done.stdout

    # The row pins what the release has: every file is kept, and the row stays, though the fresh build differs.
    done, plan, _ = run(script, pins=old, on_release=old)
    assert done.returncode == 0, done.stderr
    assert plan == [], plan
    assert all(digest(old[t]) in done.stdout for t in TARGETS), done.stdout
    assert "::warning::" in done.stderr, done.stderr

    # The release has other bytes than the row pins: refused, with nothing planned.
    other = dict(old, **{"macos-arm64": b"tampered"})
    done, plan, _ = run(script, pins=old, on_release=other)
    assert done.returncode == 1 and plan == [], (done.returncode, plan)
    assert "macos-arm64" in done.stderr, done.stderr

    # The row pins a file the release does not have: refused.
    done, plan, _ = run(script, pins=old, on_release={t: old[t] for t in list(TARGETS)[:4]})
    assert done.returncode == 1 and plan == [], (done.returncode, plan)

    # The row pins two targets: those are kept, the other three uploaded.
    two = {t: old[t] for t in list(TARGETS)[:2]}
    done, plan, names = run(script, pins=two, on_release=two)
    assert done.returncode == 0, done.stderr
    assert plan == [f"upload {names[t]}" for t in list(TARGETS)[2:]], plan

    # Files on the release that no row pins: refused off the default branch, replaced on it.
    done, plan, _ = run(script, on_release=old)
    assert done.returncode == 1 and plan == [], (done.returncode, plan)
    done, plan, names = run(script, on_release=old, may_replace="yes")
    assert done.returncode == 0, done.stderr
    assert plan == [f"replace {names[t]}" for t in TARGETS], plan

    # A row of another API pins nothing here: the same as no row.
    done, plan, _ = run(script, row_api="1.3", pins=old, on_release=old)
    assert done.returncode == 1 and plan == [], (done.returncode, plan)
    done, plan, names = run(script, row_api="1.3", pins=old, on_release=old, may_replace="yes")
    assert done.returncode == 0 and plan == [f"replace {names[t]}" for t in TARGETS], (done.stderr, plan)

    print("native-prebuilt plan: 9 cases passed")


if __name__ == "__main__":
    main()
