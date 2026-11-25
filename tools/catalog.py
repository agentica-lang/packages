"""Checks the catalog metadata of the packages and writes the data file that the site reads.

Usage: python3 -I tools/catalog.py [--root DIR] [--out FILE]

A package is a folder of ROOT with an agentica.toml. Its metadata is the front matter of PACKAGE/docs/_index.md, not
the manifest: `agentica check` rejects an unknown key of agentica.toml on every Agentica release the packages use
(0.31 to 0.38), so a `category` there would break each package. The fields:

- description (required): one line of at most MAX_DESCRIPTION characters, the one the catalog shows;
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

MAX_DESCRIPTION = 160

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
    for number, line in enumerate(match.group(1).splitlines(), start=2):
        key = KEY.match(line)
        if key:
            fields[key.group(1)] = key.group(2)
        elif line[:1] in (" ", "\t") and line.strip():
            raise ValueError(f"line {number}: an indented line continues the field above; write each field on one line")
    return fields


def keywords(text: str) -> list[str] | None:
    """`[a, b]` as a list; None when the text is not a list in one line."""
    text = text.strip()
    if not (text.startswith("[") and text.endswith("]")):
        return None
    return [scalar(item) for item in text[1:-1].split(",") if item.strip()]


def pre_release_key(pre: str) -> list[tuple[int, int, str]]:
    """The dot-separated parts of a pre-release, as semver compares them: numbers as numbers (alpha.10 is above
    alpha.2), and a number below any text."""
    return [(0, int(part), "") if part.isdigit() else (1, 0, part) for part in pre.split(".")]


def latest_tag(root: pathlib.Path, name: str) -> str | None:
    try:
        listed = subprocess.run(["git", "tag", "--list", f"{name}-*"], cwd=root, capture_output=True, text=True)
    except OSError as error:
        print(f"catalog: no git ({error}): the tags of {name} are unknown", file=sys.stderr)
        return None
    if listed.returncode != 0:
        print(f"catalog: git tag failed ({listed.stderr.strip()}): the tags of {name} are unknown", file=sys.stderr)
        return None
    found = []
    for tag in listed.stdout.split():
        match = re.match(TAG.format(name=re.escape(name)), tag)
        if match:
            major, minor, patch, pre = match.groups()
            # Any release is above every pre-release.
            found.append((pre is None, (int(major), int(minor), int(patch)), pre_release_key(pre or "0"), tag))
    return max(found)[3] if found else None


def page_metadata(page: str, path: pathlib.Path, problems: list[str]) -> tuple[str, str, list[str]]:
    """The description, the category and the keywords of a package page; a problem is added for each one that is
    wrong, and its value is then empty."""
    try:
        fields = front_matter(path)
        raw = fields.get("description", "")
        if raw[:1] not in ('"', "'") and (": " in raw or " #" in raw):
            raise ValueError("description has ': ' or ' #' and is not in quotes, which YAML reads as something else")
        description = scalar(raw)
        category = scalar(fields.get("category", ""))
        words = keywords(fields["keywords"]) if "keywords" in fields else []
    except ValueError as error:
        problems.append(f"{page}: {error}")
        return "", "", []
    if description in ("", ">", "|", ">-", "|-"):
        problems.append(f"{page}: description is missing or not on one line")
        description = ""
    elif len(description) > MAX_DESCRIPTION:
        problems.append(f"{page}: description has {len(description)} characters; at most {MAX_DESCRIPTION}")
    if category not in CATEGORIES:
        problems.append(f"{page}: category {category!r} is not one of: {', '.join(CATEGORIES)}")
    if words is None or any(not word for word in words):
        problems.append(f"{page}: keywords must be a list in one line, such as [csv, rfc4180]")
        words = []
    return description, category, words


def package(root: pathlib.Path, name: str, problems: list[str]) -> dict:
    page = f"{name}/docs/_index.md"
    path = root / page
    if path.is_file():
        description, category, words = page_metadata(page, path, problems)
    else:
        problems.append(f"{page}: missing; it is the package page and holds its category and description")
        description, category, words = "", "", []
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
