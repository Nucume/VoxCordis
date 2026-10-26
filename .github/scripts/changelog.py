#!/usr/bin/env python3
"""CHANGELOG.md helpers for the Release workflow.

  changelog.py notes <version> <CHANGELOG.md>
      Prints the notes for <version>: its own `## <version>` section, or the
      `## Unreleased` section when it has none (a tag pushed before the
      heading was renamed). Lines like `{{action:...}}` are left out.

  changelog.py release <version> <tagged CHANGELOG.md> <CHANGELOG.md>
      Files the notes that went out with <version> under `## <version>` in
      the second file (main's), leaving a fresh `## Unreleased` above it for
      anything merged after the tag. Does nothing if main already has a
      section for <version>. Exits 0 either way; prints what it did.
"""

import re
import sys

ACTION = re.compile(r"^\s*\{\{action:[a-z0-9-]+\}\}\s*$")


def heading(line):
    """The `## ` heading's name, with a leading v taken off; None otherwise."""
    if not line.startswith("## "):
        return None
    name = line[3:].split()[0] if line[3:].split() else ""
    return name[1:] if re.match(r"^v\d", name) else name


def sections(text):
    """(preamble lines, [(name, heading line, body lines)])."""
    pre, out = [], []
    for line in text.split("\n"):
        name = heading(line)
        if name is not None:
            out.append((name, line, []))
        elif out:
            out[-1][2].append(line)
        else:
            pre.append(line)
    return pre, out


def find(secs, name):
    for s in secs:
        if s[0].lower() == name.lower():
            return s
    return None


def strip(lines):
    while lines and not lines[0].strip():
        lines = lines[1:]
    while lines and not lines[-1].strip():
        lines = lines[:-1]
    return lines


def notes(version, path):
    _, secs = sections(open(path, encoding="utf-8").read())
    s = find(secs, version) or find(secs, "Unreleased")
    if s is None:
        return ""
    return "\n".join(l for l in strip(s[2]) if not ACTION.match(l))


def release(version, tagged_path, main_path):
    _, tagged = sections(open(tagged_path, encoding="utf-8").read())
    text = open(main_path, encoding="utf-8").read()
    pre, secs = sections(text)
    if find(secs, version):
        print(f"CHANGELOG.md on main already has ## {version}.")
        return False
    shipped = find(tagged, version) or find(tagged, "Unreleased")
    shipped_body = strip(shipped[2]) if shipped else []
    if not shipped_body:
        print(f"No notes went out with {version}; nothing to file.")
        return False

    # Main's Unreleased minus what shipped: notes merged after the tag.
    current = find(secs, "Unreleased")
    taken = set(l for l in shipped_body if l.strip() and not l.startswith("#"))
    later = []
    for line in strip(current[2]) if current else []:
        if line.strip() and not line.startswith("#") and line in taken:
            continue
        later.append(line)
    # Drop ### headings that lost all their lines.
    kept = []
    for i, line in enumerate(later):
        if line.startswith("### "):
            rest = later[i + 1 :]
            nxt = next((j for j, l in enumerate(rest) if l.startswith("### ")), len(rest))
            if not any(l.strip() for l in rest[:nxt]):
                continue
        kept.append(line)
    kept = strip(kept)
    later_body = [""] + kept + [""] if kept else [""]

    new = []
    for s in secs:
        if current is not None and s is current:
            continue
        new.append(s)
    filed = [
        ("Unreleased", "## Unreleased", later_body),
        (version, f"## {version}", [""] + shipped_body + [""]),
    ]
    new[0:0] = filed
    out = "\n".join(pre)
    for _, head, body in new:
        out += "\n" + head + "\n" + "\n".join(body).rstrip("\n") + "\n"
    out = out.rstrip("\n") + "\n"
    open(main_path, "w", encoding="utf-8").write(out)
    print(f"Filed the shipped notes under ## {version}.")
    return True


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "notes" and len(sys.argv) == 4:
        print(notes(sys.argv[2], sys.argv[3]))
    elif cmd == "release" and len(sys.argv) == 5:
        release(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
