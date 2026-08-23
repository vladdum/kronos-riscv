#!/usr/bin/env python3
"""Docs era-lint: every diagram declares the stage it depicts, and any
diagram older than the active stage is embedded with an era caption.
Active stage = first 'In progress' or last 'Complete' row of README's
Staged Development table."""
import json, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
fail = []

def stage_num(s):
    m = re.match(r"stage(\d+)", s or "")
    return int(m.group(1)) if m else None

readme = (ROOT / "README.md").read_text()
rows = re.findall(r"^\|\s*(\d+)[a-z]?\s*\|.*\|\s*(In progress|Complete[^|]*)\s*\|",
                  readme, re.M)
active = max(int(r[0]) for r in rows)

for j in (ROOT / "docs/diagrams/src").glob("*.json"):
    d = json.loads(j.read_text())
    if stage_num(d.get("depicts")) is None:
        fail.append(f"{j.relative_to(ROOT)}: missing \"depicts\": \"stage<N>\"")

for md in (ROOT / "docs").glob("*.md"):
    text = md.read_text().splitlines()
    for i, line in enumerate(text):
        if line.strip().startswith("```mermaid"):
            nxt = text[i + 1].strip() if i + 1 < len(text) else ""
            m = re.match(r"%%\s*depicts:\s*(stage\d+\w*)", nxt)
            if not m:
                fail.append(f"{md.relative_to(ROOT)}:{i+1}: mermaid block missing '%% depicts: stage<N>'")
                continue
            n = stage_num(m.group(1))
            if n is not None and n < active:
                ctx = "\n".join(text[max(0, i - 3):i])
                if "(era: stage" not in ctx:
                    fail.append(f"{md.relative_to(ROOT)}:{i+1}: depicts stage{n} < active stage{active} without an '(era: stage{n})' caption")
        if ".svg" in line and "diagrams" in line:
            m = re.search(r"\((docs/)?diagrams/svg/([\w-]+)\.svg\)", line)
            if m:
                src = ROOT / "docs/diagrams/src" / (m.group(2) + ".json")
                if src.exists():
                    n = stage_num(json.loads(src.read_text()).get("depicts"))
                    ctx = "\n".join(text[max(0, i - 3):i + 1])
                    if n is not None and n < active and "(era: stage" not in ctx:
                        fail.append(f"{md.relative_to(ROOT)}:{i+1}: embeds stage{n} diagram without era caption")

if fail:
    print("docs_lint: FAIL"); [print("  " + f) for f in fail]; sys.exit(1)
print(f"docs_lint: OK (active stage {active})")
