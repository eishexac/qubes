"""Render each .sls through Jinja with stubbed salt/grains, then parse the YAML.

This will not catch a wrong qvm.* state signature (that needs Qubes), but it
does catch every Jinja and YAML error, which is the class of bug that is
tedious to debug over qubesctl output.
"""
import sys, yaml, jinja2

class Pillar:
    def get(self, key, default=None):
        return default

def salt_get(name):
    return {"pillar.get": Pillar().get}[name]

class SaltDict(dict):
    def __getitem__(self, k):
        if k == "pillar.get":
            return Pillar().get
        raise KeyError(k)

targets = {
    "salt/wg-template.sls": ["dom0", "wgq-debian-13"],
    "salt/wg-qubes.sls": ["dom0"],
    "salt/top.sls": ["dom0"],
}

env = jinja2.Environment(undefined=jinja2.StrictUndefined, trim_blocks=False)
bad = 0
for path, ids in targets.items():
    src = open(path).read()
    for vm_id in ids:
        label = f"{path} (grains.id={vm_id})"
        try:
            rendered = env.from_string(src).render(salt=SaltDict(), grains={"id": vm_id})
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
