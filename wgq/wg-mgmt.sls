{#-
    wgq: the infrastructure qube.

    dom0 only:  sudo qubesctl --show-output state.apply wgq.wg-mgmt

    This creates ONLY wgq-mgmt, the provisioning qube. Zones are user
    lifecycle, not installation: create each one deliberately with

        sudo wgq zone add <zone>

    which applies wgq.wg-zone for that name (sys-wgq-<zone> plus
    sys-fw-<zone>, tagged and marked). See wg-zone.sls for the topology
    reasoning.

    Why wgq-mgmt is not behind the VPN: a management qube that needs the
    tunnel to reach the provider cannot fix a broken tunnel, and routing
    account authentication through a tunnel keyed to that same account is
    its own problem.
-#}

{% set tpl      = salt['pillar.get']('wgq:template', 'debian-13-wgq') %}
{% set upstream = salt['pillar.get']('wgq:upstream', 'sys-firewall') %}
{% set mgmt     = salt['pillar.get']('wgq:mgmt', 'wgq-mgmt') %}
{#- The custom label (created in wg-icons.sls) keeps mgmt's yellow but
    gives it a wgq-scoped name, which is what resolves the terminal-cube
    icon 'appvm-wgq-mgmt' without shadowing any stock icon. -#}
{% set label    = salt['pillar.get']('wgq:label_mgmt', 'wgq-mgmt') %}

include:
  - wgq.wg-icons

{{ mgmt }}-present:
  qvm.present:
    - name: {{ mgmt }}
    - template: {{ tpl }}
    - label: {{ label }}
    - require:
      - cmd: wgq-label-wgq-mgmt

# Adoption guard: wgq converges only qubes it made. The created-by-wgq
# tag proves it; a qube already wearing a wgq label was dressed by dom0
# (no VM can set labels), so it is adopted and tagged -- which is also
# how a fresh create passes, born wearing the label. Anything else
# under this name is somebody else's qube: the mutating states below
# require this one, so a refusal here leaves the stranger untouched.
{{ mgmt }}-owned:
  cmd.run:
    - name: |
        l=$(qvm-prefs {{ mgmt }} label)
        case "$l" in
        wgq|wgq-fw|wgq-mgmt|wgq-tpl)
            qvm-tags {{ mgmt }} add created-by-wgq; exit 0;;
        esac
        echo "wgq: qube {{ mgmt }} exists but was not created by wgq" >&2
        echo "(label $l, no created-by-wgq tag). If it is yours from an" >&2
        echo "older wgq install, adopt it and re-run:" >&2
        echo "    qvm-tags {{ mgmt }} add created-by-wgq" >&2
        exit 1
    - unless: qvm-tags {{ mgmt }} list | grep -qx created-by-wgq
    - require:
      - qvm: {{ mgmt }}-present

# An existing mgmt converges onto the wgq label on re-run.
{{ mgmt }}-label:
  cmd.run:
    - name: qvm-prefs {{ mgmt }} label {{ label }}
    - unless: qvm-prefs {{ mgmt }} label | grep -qx {{ label }}
    - require:
      - qvm: {{ mgmt }}-present
      - cmd: {{ mgmt }}-owned

# Same diet as the zone qubes (see wg-zone.sls for the hardware numbers):
# a provisioning CLI that is idle between runs needs 400 static MB, not a
# 4 GB balloon ceiling -- qmemman's re-trading ran this qube's xen-balloon
# worker at 90% CPU on the machine that surfaced it.
{{ mgmt }}-prefs:
  qvm.prefs:
    - name: {{ mgmt }}
    - netvm: {{ upstream }}
    - memory: 400
    - maxmem: 0
    - vcpus: 1
    - autostart: False
    - require:
      - qvm: {{ mgmt }}-present
      - cmd: {{ mgmt }}-owned

{{ mgmt }}-no-balloon:
  qvm.service:
    - name: {{ mgmt }}
    - disable:
      - meminfo-writer
    - require:
      - qvm: {{ mgmt }}-present
      - cmd: {{ mgmt }}-owned
