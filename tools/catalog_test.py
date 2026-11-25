"""Runs tools/catalog.py on made-up package trees: what it accepts and what it refuses.

Usage: python3 -I tools/catalog_test.py
"""

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "catalog.py"
PAGE = "---\ntitle: demo\ndescription: A demo package.\ncategory: Tooling\nkeywords: [demo, 'a b']\n---\n\nText.\n"


def make_package(root: pathlib.Path, name: str, page: str = PAGE, version: str | None = "0.35.0 abc") -> None:
    (root / name / "docs").mkdir(parents=True)
    (root / name / "agentica.toml").write_text(f'name = "{name}"\n')
    if version is not None:
        (root / name / "AGENTICA_VERSION").write_text(version + "\n")
    (root / name / "docs" / "_index.md").write_text(page)


def git(root: pathlib.Path, *args: str) -> None:
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args], cwd=root, check=True,
                   capture_output=True)


def run(root: pathlib.Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-I", str(SCRIPT), "--root", str(root), *args], capture_output=True, text=True)


class CatalogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.dir.name)

    def tearDown(self) -> None:
        self.dir.cleanup()

    def test_writes_the_data_of_a_valid_tree(self) -> None:
        make_package(self.root, "demo")
        make_package(self.root, "pre", PAGE.replace("demo", "pre"))
        make_package(self.root, "untagged", PAGE.replace("demo", "untagged"))
        git(self.root, "init", "-q")
        git(self.root, "commit", "-q", "--allow-empty", "-m", "x")
        # Tags of other packages whose names start with "demo" must not count for demo.
        for tag in ["demo-0.1.0", "demo-0.2.0-alpha.1", "demo-0.2.0", "demo-0.10.0-alpha.1", "demo-0.9.0",
                    "demo-x-1.0.0", "demo2-1.0.0", "other-9.0.0", "pre-0.1.0-alpha.2", "pre-0.1.0-alpha.10"]:
            git(self.root, "tag", tag)
        out = self.root / "data" / "catalog.json"
        result = run(self.root, "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        packages = {p["name"]: p for p in json.loads(out.read_text())["packages"]}
        self.assertEqual(packages["demo"], {"name": "demo", "category": "Tooling", "description": "A demo package.",
                                            "keywords": ["demo", "a b"], "tag": "demo-0.9.0", "agentica": "0.35.0"})
        self.assertEqual(packages["pre"]["tag"], "pre-0.1.0-alpha.10")
        self.assertIsNone(packages["untagged"]["tag"])

    def test_no_git_repository_gives_no_tag_and_a_note(self) -> None:
        make_package(self.root, "demo")
        out = self.root / "catalog.json"
        result = run(self.root, "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(json.loads(out.read_text())["packages"][0]["tag"])
        self.assertIn("tags of demo are unknown", result.stderr)

    def test_refuses_what_the_catalog_needs(self) -> None:
        cases = {
            "no category": (PAGE.replace("category: Tooling\n", ""), "category ''"),
            "unknown category": (PAGE.replace("Tooling", "Misc"), "category 'Misc'"),
            "no description": (PAGE.replace("description: A demo package.\n", ""), "description is missing"),
            "folded description": (PAGE.replace("A demo package.", ">\n  A demo."), "an indented line"),
            "keywords as text": (PAGE.replace("[demo, 'a b']", "demo"), "keywords must be a list"),
            "no page": (None, "missing"),
            "long description": (PAGE.replace("A demo package.", "x" * 161), "description has 161 characters"),
            "indented line": (PAGE.replace("keywords: [demo, 'a b']", "keywords:\n  - demo"), "an indented line"),
            "colon in plain text": (PAGE.replace("A demo package.", "A demo: package."), "not in quotes"),
            "bad escape": (PAGE.replace("description: A demo package.", 'description: "a\\qb"'), "Invalid"),
            "no agentica version": (PAGE, "demo/AGENTICA_VERSION: missing"),
        }
        for label, (page, expected) in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                make_package(root, "demo", page or PAGE, None if label == "no agentica version" else "0.35.0 abc")
                if page is None:
                    (root / "demo" / "docs" / "_index.md").unlink()
                result = run(root)
                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
