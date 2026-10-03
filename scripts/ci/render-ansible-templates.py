#!/usr/bin/env python3
"""Render every Ansible role template (*.j2) so syntax errors surface in CI.

ansible-lint and `--syntax-check` never render templates, so a Jinja error
(e.g. bash's array-length expansion opening a `{#` comment) only shows up
on a live host. This renders each template with its role defaults plus
group_vars, leaving anything else undefined-but-harmless, and writes the
output to OUTDIR so the shell-script templates can be shellchecked.

usage: render-ansible-templates.py OUTDIR
"""

import pathlib
import sys

import jinja2
import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2] / "ansible"


def load_vars(*files: pathlib.Path) -> dict:
    merged: dict = {}
    for f in files:
        if f.is_file():
            merged.update(yaml.safe_load(f.read_text()) or {})
    return merged


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    env = jinja2.Environment(undefined=jinja2.ChainableUndefined, keep_trailing_newline=True)
    group_vars = ROOT / "group_vars" / "all.yml"
    failures = 0
    for tpl in sorted(ROOT.glob("roles/*/templates/*.j2")):
        role = tpl.parents[1]
        values = load_vars(group_vars, role / "defaults" / "main.yml")
        values.setdefault("ansible_managed", "Ansible managed")
        try:
            rendered = env.from_string(tpl.read_text()).render(**values)
        except jinja2.TemplateError as exc:
            print(f"FAIL {tpl.relative_to(ROOT.parent)}: {exc}", file=sys.stderr)
            failures += 1
            continue
        (out / f"{role.name}__{tpl.stem}").write_text(rendered)
        print(f"ok   {tpl.relative_to(ROOT.parent)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
