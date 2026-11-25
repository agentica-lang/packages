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


def make_package(root: pathlib.Path, name: str, page: str = PAGE, version: str = "0.35.0 abc") -> None:
    (root / name / "docs").mkdir(parents=True)
    (root / name / "agentica.toml").write_text(f'name = "{name}"\n')
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
        git(self.root, "init", "-q")
        git(self.root, "commit", "-q", "--allow-empty", "-m", "x")
        for tag in ["demo-0.1.0", "demo-0.2.0-alpha.1", "demo-0.2.0", "demo-0.10.0-alpha.1", "demo-0.9.0", "other-9.0.0"]:
            git(self.root, "tag", tag)
        out = self.root / "data" / "catalog.json"
        result = run(self.root, "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        package = json.loads(out.read_text())["packages"][0]
        self.assertEqual(package, {"name": "demo", "category": "Tooling", "description": "A demo package.",
                                   "keywords": ["demo", "a b"], "tag": "demo-0.9.0", "agentica": "0.35.0"})

    def test_refuses_what_the_catalog_needs(self) -> None:
        cases = {
            "no category": (PAGE.replace("category: Tooling\n", ""), "category ''"),
            "unknown category": (PAGE.replace("Tooling", "Misc"), "category 'Misc'"),
            "no description": (PAGE.replace("description: A demo package.\n", ""), "description is missing"),
            "folded description": (PAGE.replace("A demo package.", ">\n  A demo."), "description is missing"),
            "keywords as text": (PAGE.replace("[demo, 'a b']", "demo"), "keywords must be a list"),
            "no page": (None, "missing"),
        }
        for label, (page, expected) in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory() as tmp:
                root = pathlib.Path(tmp)
                make_package(root, "demo", page or PAGE)
                if page is None:
                    (root / "demo" / "docs" / "_index.md").unlink()
                result = run(root)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"demo/docs/_index.md: ", result.stderr)
                self.assertIn(expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
