"""Checks the catalog metadata of the packages and writes the data file that the site reads.

Usage: python3 -I tools/catalog.py [--root DIR] [--out FILE]

A package is a folder of ROOT with an agentica.toml. Its metadata is the front matter of PACKAGE/docs/_index.md, not
the manifest: `agentica check` rejects an unknown key of agentica.toml on every Agentica release the packages use
(0.31 to 0.38), so a `category` there would break each package. The fields:

- description (required): one line, the one the catalog shows;
- category (required): one of CATEGORIES;
- keywords (optional): a list in one line, `[csv, rfc4180]`, which the catalog filter searches.

Every problem is printed as `PACKAGE/docs/_index.md: what is wrong`, and the exit code is 1. With --out the data file
is written when there is no problem: the categories in order, and for each package its metadata, its latest tag
(PACKAGE-X.Y.Z of the git tags: the highest version, a pre-release only when there is no other) and its Agentica
version (the first word of PACKAGE/AGENTICA_VERSION). `make site` runs it, and the `plan` job of ci.yml checks.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

# One category per package, by what the package is for and not by how it is built (a native module is in the category
# of what it does). Add a category here and nothing else: the site reads the list from the data file.
CATEGORIES = ["Web and HTTP", "Networking", "Data formats", "Storage", "Infrastructure", "Tooling"]

FRONT_MATTER = re.compile(r"\A---\n(.*?)\n---\n", re.S)
KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$")
TAG = r"^{name}-(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$"


def scalar(text: str) -> str:
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] == '"':
        return json.loads(text)
    if len(text) >= 2 and text[0] == text[-1] == "'":
        return text[1:-1].replace("''", "'")
    return text


def front_matter(path: pathlib.Path) -> dict[str, str]:
    """The `key: value` lines of the front matter; a value is the text after the colon, as written."""
    match = FRONT_MATTER.match(path.read_text())
    if not match:
        return {}
    fields = {}
    for line in match.group(1).splitlines():
        key = KEY.match(line)
        if key:
            fields[key.group(1)] = key.group(2)
    return fields


def keywords(text: str) -> list[str] | None:
    """`[a, b]` as a list; None when the text is not a list in one line."""
    text = text.strip()
    if not (text.startswith("[") and text.endswith("]")):
        return None
    return [scalar(item) for item in text[1:-1].split(",") if item.strip()]


def latest_tag(root: pathlib.Path, name: str) -> str | None:
    listed = subprocess.run(["git", "tag", "--list", f"{name}-*"], cwd=root, capture_output=True, text=True).stdout
    found = []
    for tag in listed.split():
        match = re.match(TAG.format(name=re.escape(name)), tag)
        if match:
            major, minor, patch, pre = match.groups()
            # Any release is above every pre-release; two pre-releases compare as text, which is enough for -alpha.N.
            found.append((pre is None, (int(major), int(minor), int(patch)), pre or "", tag))
    return max(found)[3] if found else None


def package(root: pathlib.Path, name: str, problems: list[str]) -> dict:
    page = f"{name}/docs/_index.md"
    path = root / page
    fields = front_matter(path) if path.is_file() else {}
    if not path.is_file():
        problems.append(f"{page}: missing; it is the package page and holds its category and description")
    description = scalar(fields.get("description", ""))
    if path.is_file() and description in ("", ">", "|", ">-", "|-"):
        problems.append(f"{page}: description is missing or not on one line")
        description = ""
    category = scalar(fields.get("category", ""))
    if path.is_file() and category not in CATEGORIES:
        problems.append(f"{page}: category {category!r} is not one of: {', '.join(CATEGORIES)}")
    words = keywords(fields["keywords"]) if "keywords" in fields else []
    if words is None or any(not word for word in words):
        problems.append(f"{page}: keywords must be a list in one line, such as [csv, rfc4180]")
        words = []
    version_file = root / name / "AGENTICA_VERSION"
    version = version_file.read_text().split()[0] if version_file.is_file() and version_file.read_text().split() else ""
    if not version:
        problems.append(f"{name}/AGENTICA_VERSION: missing or empty; its first word is the Agentica version")
    return {"name": name, "category": category, "description": description, "keywords": words,
            "tag": latest_tag(root, name), "agentica": version}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument("--out", type=pathlib.Path)
    args = parser.parse_args()
    names = sorted(p.parent.name for p in args.root.glob("*/agentica.toml"))
    problems: list[str] = []
    packages = [package(args.root, name, problems) for name in names]
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps({"categories": CATEGORIES, "packages": packages}, indent=1) + "\n")
    print(f"catalog: {len(packages)} packages in {len({p['category'] for p in packages})} categories")
    return 0


if __name__ == "__main__":
    sys.exit(main())
