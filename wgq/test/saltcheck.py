"""Render each .sls through Jinja with stubbed salt/grains, then parse the YAML.

This will not catch a wrong qvm.* state signature (that needs Qubes), but it
does catch every Jinja and YAML error, which is the class of bug that is
tedious to debug over qubesctl output.
"""
import sys, yaml, jinja2

class Pillar:
    def __init__(self, overrides=None):
        self.overrides = overrides or {}

    def get(self, key, default=None):
        return self.overrides.get(key, default)

class SaltDict(dict):
    def __init__(self, overrides=None):
        super().__init__()
        self.overrides = overrides

    def __getitem__(self, k):
        if k == "pillar.get":
            return Pillar(self.overrides).get
        raise KeyError(k)

targets = {
    "wg-template.sls": ["dom0", "debian-13-wgq"],
    "wg-mgmt.sls": ["dom0"],
    "wg-zone.sls": ["dom0"],
    "wg-icons.sls": ["dom0"],
    "wg-cli.sls": ["dom0"],
    "top.sls": ["dom0"],
}

# wg-zone renders a deliberate failure state when no zone is in pillar, so
# every branch needs a parse: the default render covers the missing-name
# branch, and these cover a normal zone plus the reserved single-VPN zone
# 'wgq' (whose VPN qube name collapses to bare sys-wgq).
pillar_overrides = {
    "wg-zone.sls": [{"wgq:zone": "ztest"}, {"wgq:zone": "wgq"}],
}

env = jinja2.Environment(undefined=jinja2.StrictUndefined, trim_blocks=False)
bad = 0
for path, ids in targets.items():
    src = open(path).read()
    pillar_cases = [None]
    if path in pillar_overrides:
        pillar_cases.extend(pillar_overrides[path])
    for vm_id in ids:
      for overrides in pillar_cases:
        label = f"{path} (grains.id={vm_id}"
        label += f", pillar={overrides})" if overrides else ")"
        try:
            rendered = env.from_string(src).render(
                salt=SaltDict(overrides), grains={"id": vm_id}
            )
        except Exception as exc:
            print(f"JINJA FAIL {label}: {exc}"); bad += 1; continue
        try:
            doc = yaml.safe_load(rendered)
        except Exception as exc:
            print(f"YAML  FAIL {label}: {exc}"); bad += 1; continue
        if doc is None:
            print(f"EMPTY      {label} (nothing renders for this target)")
            continue
        keys = list(doc)
        print(f"ok         {label}: {len(keys)} state id(s)")
        for k in keys:
            v = doc[k]
            if isinstance(v, dict):
                for state in v:
                    if "." not in state and k != "base":
                        print(f"  ?? {k}: '{state}' has no module.function form")
sys.exit(1 if bad else 0)
