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

# An existing mgmt converges onto the wgq label on re-run.
{{ mgmt }}-label:
  cmd.run:
    - name: qvm-prefs {{ mgmt }} label {{ label }}
    - unless: qvm-prefs {{ mgmt }} label | grep -qx {{ label }}
    - require:
      - qvm: {{ mgmt }}-present

{{ mgmt }}-prefs:
  qvm.prefs:
    - name: {{ mgmt }}
    - netvm: {{ upstream }}
    - autostart: False
    - require:
      - qvm: {{ mgmt }}-present
