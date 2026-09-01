{#-
    wgq: one identity zone.

    Never applied bare -- the zone name arrives as pillar, normally via
    the dom0 helper:

        sudo /srv/salt/wgq/dom0/wgq-zone add <zone>

    Topology built here, per zone:

        sys-net - sys-firewall - sys-wgq-<zone> - sys-fw-<zone> - clients

    Why the downstream firewall qube: Qubes states that running networking
    services in a qube that also runs the Qubes firewall service is
    unsupported, and prescribes exactly this shape. Clients point at
    sys-fw-<zone> permanently, so switching which VPN backs them is one
    qvm-prefs away and touches no client. The firewall qube's name stays
    deliberately generic: its wg-ness is incidental and may not last.
-#}

{% set zone     = salt['pillar.get']('wgq:zone', '') %}
{% set tpl      = salt['pillar.get']('wgq:template', 'debian-13-wgq') %}
{% set upstream = salt['pillar.get']('wgq:upstream', 'sys-firewall') %}
{% set label    = salt['pillar.get']('wgq:label', 'orange') %}
{#- The reserved zone 'wgq' (single-VPN default) collapses the VPN qube
    name to bare sys-wgq; the firewall name follows the normal grammar. -#}
{% set vpnq = 'sys-wgq' if zone == 'wgq' else 'sys-wgq-' ~ zone %}

{% if not zone %}

wgq-zone-name-missing:
  cmd.run:
    - name: >
        echo "wgq: no zone name in pillar. Create zones with:
        sudo /srv/salt/wgq/dom0/wgq-zone add <zone>" >&2; exit 1

{% else %}

wgq-vpn-{{ zone }}-present:
  qvm.present:
    - name: {{ vpnq }}
    - template: {{ tpl }}
    - label: {{ label }}

wgq-vpn-{{ zone }}-prefs:
  qvm.prefs:
    - name: {{ vpnq }}
    - netvm: {{ upstream }}
    - provides_network: True
    # Left off deliberately. A half-configured VPN qube coming up at every
    # boot while you are still iterating is worse than starting it by hand.
    - autostart: False
    - require:
      - qvm: wgq-vpn-{{ zone }}-present

# The service flag is what 50-wgq keys its role decision on: a marked qube
# that is not yet configured FAILS CLOSED (forwards nothing) instead of
# behaving like an ordinary proxy -- the clear-forwarding window found on
# the first hardware run. qvm-features is used rather than a Salt state so
# the security-relevant command is visible in this file.
wgq-vpn-{{ zone }}-service:
  cmd.run:
    - name: qvm-features {{ vpnq }} service.wgq-vpn 1
    - unless: qvm-features {{ vpnq }} service.wgq-vpn | grep -qx 1
    - require:
      - qvm: wgq-vpn-{{ zone }}-present

# The tag is what the dom0 policy grants against, so wgq-mgmt can rewrite
# the firewall of these qubes and of nothing else.
wgq-vpn-{{ zone }}-tag:
  cmd.run:
    - name: qvm-tags {{ vpnq }} add wgq-zone
    - unless: qvm-tags {{ vpnq }} list | grep -qx wgq-zone
    - require:
      - qvm: wgq-vpn-{{ zone }}-present

sys-fw-{{ zone }}-present:
  qvm.present:
    - name: sys-fw-{{ zone }}
    - template: {{ tpl }}
    - label: {{ label }}

sys-fw-{{ zone }}-prefs:
  qvm.prefs:
    - name: sys-fw-{{ zone }}
    - netvm: {{ vpnq }}
    - provides_network: True
    - autostart: False
    - require:
      - qvm: sys-fw-{{ zone }}-present
      - qvm: wgq-vpn-{{ zone }}-prefs

{% endif %}
