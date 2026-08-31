{#-
    wgq: the qubes.

    dom0 only:  sudo qubesctl --show-output state.apply wgq.wg-qubes

    Topology built here, per zone:

        sys-net - sys-firewall -+- sys-vpn-<zone> - sys-firewall-<zone> - clients
                                +- wgq-mgmt        (provisioning only)

    Why the downstream firewall qube: Qubes states that running networking
    services in a qube that also runs the Qubes firewall service is
    unsupported, and prescribes exactly this shape. It also means clients
    point at sys-firewall-<zone> permanently, so switching which VPN backs
    them is one qvm-prefs away and touches no client.

    Why wgq-mgmt is not behind the VPN: a management qube that needs the
    tunnel to reach the provider cannot fix a broken tunnel, and routing
    account authentication through a tunnel keyed to that same account is
    its own problem.

    Adding a zone is a one-line change to `zones` below, or to the
    wgq:zones pillar.
-#}

{% set zones    = salt['pillar.get']('wgq:zones', ['work']) %}
{% set tpl      = salt['pillar.get']('wgq:template', 'wgq-debian-13') %}
{% set upstream = salt['pillar.get']('wgq:upstream', 'sys-firewall') %}
{% set mgmt     = salt['pillar.get']('wgq:mgmt', 'wgq-mgmt') %}
{% set label    = salt['pillar.get']('wgq:label', 'orange') %}

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

{% for zone in zones %}

sys-vpn-{{ zone }}-present:
  qvm.present:
    - name: sys-vpn-{{ zone }}
    - template: {{ tpl }}
    - label: {{ label }}

sys-vpn-{{ zone }}-prefs:
  qvm.prefs:
    - name: sys-vpn-{{ zone }}
    - netvm: {{ upstream }}
    - provides_network: True
    # Left off deliberately. A half-configured VPN qube coming up at every
    # boot while you are still iterating is worse than starting it by hand.
    # Turn it on once `wgq verify` passes.
    - autostart: False
    - require:
      - qvm: sys-vpn-{{ zone }}-present

# The tag is what the dom0 policy grants against, so wgq-mgmt can rewrite
# the firewall of these qubes and of nothing else. qvm-tags is used rather
# than a Salt state because the tag is a security boundary and this way the
# command is visible in the file.
sys-vpn-{{ zone }}-tag:
  cmd.run:
    - name: qvm-tags sys-vpn-{{ zone }} add wgq-zone
    - unless: qvm-tags sys-vpn-{{ zone }} list | grep -qx wgq-zone
    - require:
      - qvm: sys-vpn-{{ zone }}-present

sys-firewall-{{ zone }}-present:
  qvm.present:
    - name: sys-firewall-{{ zone }}
    - template: {{ tpl }}
    - label: {{ label }}

sys-firewall-{{ zone }}-prefs:
  qvm.prefs:
    - name: sys-firewall-{{ zone }}
    - netvm: sys-vpn-{{ zone }}
    - provides_network: True
    - autostart: False
    - require:
      - qvm: sys-firewall-{{ zone }}-present
      - qvm: sys-vpn-{{ zone }}-prefs

{% endfor %}
