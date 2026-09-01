{#-
    wgq: the infrastructure qube.

    dom0 only:  sudo qubesctl --show-output state.apply wgq.wg-mgmt

    This creates ONLY wgq-mgmt, the provisioning qube. Zones are user
    lifecycle, not installation: create each one deliberately with

        sudo /srv/salt/wgq/dom0/wgq-zone add <zone>

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

{{ mgmt }}-present:
  qvm.present:
    - name: {{ mgmt }}
    - template: {{ tpl }}
    - label: yellow

{{ mgmt }}-prefs:
  qvm.prefs:
    - name: {{ mgmt }}
    - netvm: {{ upstream }}
    - autostart: False
    - require:
      - qvm: {{ mgmt }}-present
