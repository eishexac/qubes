{#-
    wgq: one identity zone.

    Never applied bare -- the zone name arrives as pillar, normally via
    the dom0 helper:

        sudo wgq zone add <zone>

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
{#- The wgq custom labels (created in wg-icons.sls): named labels are
    what scope the icons to wgq alone, and their colours follow the
    system's own grammar -- red edge like sys-net, green filter like
    sys-firewall. -#}
{% set label    = salt['pillar.get']('wgq:label', 'wgq') %}
{% set label_fw = salt['pillar.get']('wgq:label_fw', 'wgq-fw') %}
{#- The reserved zone 'wgq' (single-VPN default) collapses the VPN qube
    name to bare sys-wgq; the firewall name follows the normal grammar. -#}
{% set vpnq = 'sys-wgq' if zone == 'wgq' else 'sys-wgq-' ~ zone %}

{% if not zone %}

wgq-zone-name-missing:
  cmd.run:
    - name: >
        echo "wgq: no zone name in pillar. Create zones with:
        sudo wgq zone add <zone>" >&2; exit 1

{% else %}

include:
  - wgq.wg-icons

wgq-vpn-{{ zone }}-present:
  qvm.present:
    - name: {{ vpnq }}
    - template: {{ tpl }}
    - label: {{ label }}
    - require:
      - cmd: wgq-label-wgq

wgq-vpn-{{ zone }}-prefs:
  qvm.prefs:
    - name: {{ vpnq }}
    - netvm: {{ upstream }}
    - provides_network: True
    # Left off deliberately. A half-configured VPN qube coming up at every
    # boot while you are still iterating is worse than starting it by hand.
    # wgq-zone starts the fresh qubes once after creating them (a halted
    # netvm cannot accept clients); every boot after that is your call.
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

# servicevm is what gives sys-net and sys-firewall their system-qube look
# and grouping in the GUI (the Service section, the dot-marked icon).
# Zone qubes are the same kind of thing -- plumbing, not a workspace --
# so they carry the same mark. wgq-mgmt deliberately does not: commands
# are typed there, so it stays an ordinary app qube.
wgq-vpn-{{ zone }}-servicevm:
  cmd.run:
    - name: qvm-features {{ vpnq }} servicevm 1
    - unless: qvm-features {{ vpnq }} servicevm | grep -qx 1
    - require:
      - qvm: wgq-vpn-{{ zone }}-present

sys-fw-{{ zone }}-servicevm:
  cmd.run:
    - name: qvm-features sys-fw-{{ zone }} servicevm 1
    - unless: qvm-features sys-fw-{{ zone }} servicevm | grep -qx 1
    - require:
      - qvm: sys-fw-{{ zone }}-present

# The tag is what the dom0 policy grants against, so wgq-mgmt can rewrite
# the firewall of these qubes and of nothing else.
wgq-vpn-{{ zone }}-tag:
  cmd.run:
    - name: qvm-tags {{ vpnq }} add wgq-zone
    - unless: qvm-tags {{ vpnq }} list | grep -qx wgq-zone
    - require:
      - qvm: wgq-vpn-{{ zone }}-present

# An existing zone converges too: labels are identity, not creation-day
# trivia, so a re-run moves old qubes onto the wgq labels.
wgq-vpn-{{ zone }}-label:
  cmd.run:
    - name: qvm-prefs {{ vpnq }} label {{ label }}
    - unless: qvm-prefs {{ vpnq }} label | grep -qx {{ label }}
    - require:
      - qvm: wgq-vpn-{{ zone }}-present

sys-fw-{{ zone }}-present:
  qvm.present:
    - name: sys-fw-{{ zone }}
    - template: {{ tpl }}
    - label: {{ label_fw }}
    - require:
      - cmd: wgq-label-wgq-fw

sys-fw-{{ zone }}-label:
  cmd.run:
    - name: qvm-prefs sys-fw-{{ zone }} label {{ label_fw }}
    - unless: qvm-prefs sys-fw-{{ zone }} label | grep -qx {{ label_fw }}
    - require:
      - qvm: sys-fw-{{ zone }}-present

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
