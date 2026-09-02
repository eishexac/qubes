{#-
    wgq: the template.

    Clones the OFFICIAL debian-13-minimal and installs from Debian's and
    Qubes' signed repositories. No template is redistributed, so the user's
    trust anchors stay Debian and ITL; this formula only supplies
    orchestration, which is text they can read.

    This file is applied twice, with different targets, because one half
    runs in dom0 and the other inside the template:

      sudo qubesctl --show-output state.apply wgq.wg-template
          dom0 branch: clone, then bootstrap the Salt connector.

      sudo qubesctl --skip-dom0 --targets=debian-13-wgq --show-output \
          state.apply wgq.wg-template
          template branch: packages and files.

    The bootstrap is not an oversight. qubes-mgmt-salt-vm-connector is the
    package that makes a qube salt-manageable, so Salt cannot be what
    installs it; that first step has to go through qvm-run from dom0.
-#}

{% set base = salt['pillar.get']('wgq:base_template', 'debian-13-minimal') %}
{% set tpl  = salt['pillar.get']('wgq:template', 'debian-13-wgq') %}
{% set label_tpl = salt['pillar.get']('wgq:label_tpl', 'wgq-tpl') %}

{% if grains['id'] == 'dom0' %}

{#- The custom label (created in wg-icons.sls) gives the template its
    own icon; black follows the stock template convention. -#}
include:
  - wgq.wg-icons

# Fail with an instruction rather than silently pulling a template down.
wgq-base-template-present:
  cmd.run:
    - name: >
        echo "wgq: base template {{ base }} is not installed. Install it with:
        sudo qubes-dom0-update qubes-template-debian-13-minimal" >&2; exit 1
    - unless: qvm-check --quiet {{ base }}

wgq-template-clone:
  qvm.clone:
    - name: {{ tpl }}
    - source: {{ base }}
    - require:
      - cmd: wgq-base-template-present

# An existing template converges onto the wgq label on re-run.
{{ tpl }}-label:
  cmd.run:
    - name: qvm-prefs {{ tpl }} label {{ label_tpl }}
    - unless: qvm-prefs {{ tpl }} label | grep -qx {{ label_tpl }}
    - require:
      - qvm: wgq-template-clone
      - cmd: wgq-label-wgq-tpl

wgq-template-salt-connector:
  cmd.run:
    - name: |
        set -e
        qvm-run --nogui --pass-io -u root {{ tpl }} \
          'apt-get -q update && apt-get -q -y install qubes-mgmt-salt-vm-connector'
        qvm-shutdown --wait {{ tpl }}
    # No ${...} anywhere in the remote command: it runs inside the VM's
    # shell, where double-quoted ${Status} would be expanded (to nothing)
    # by the shell before dpkg-query ever saw its format string -- which
    # made this guard always fail and the bootstrap re-run on every apply.
    - unless: >
        qvm-run --nogui --pass-io -u root {{ tpl }}
        'dpkg-query -s qubes-mgmt-salt-vm-connector 2>/dev/null
        | grep -q "^Status: install ok installed"'
    - require:
      - qvm: wgq-template-clone

{% else %}

wgq-packages:
  pkg.installed:
    - pkgs:
      # Documented minimum for the NetVM/FirewallVM roles. Brings in
      # nftables, conntrack and iproute2, so the firewall script and the
      # conntrack flush need nothing extra.
      - qubes-core-agent-networking
      # Minimal templates omit this; qvm-run -u root from dom0 works
      # without it, but in-qube sudo does not.
      - qubes-core-agent-passwordless-root
      - wireguard-tools
      - tcpdump
      - vim-tiny
      - less
      # Deliberately NOT installed:
      #   qubes-core-agent-network-manager - NetworkManager's WireGuard
      #     support is an independent reimplementation whose import silently
      #     drops wg-quick's PreUp/PostUp/PostDown hooks.
      #   qubes-vm-recommended - pulls in most of the extras that starting
      #     from a minimal template exists to avoid.
      #   any terminal emulator - use qvm-run -u root or qvm-console-dispvm.

# Everything below lands in /etc and /usr proper, never /usr/local: in
# template-based qubes /usr/local is the qube's own /rw/usrlocal, seeded
# from the template once on the qube's FIRST boot and never again. A tool
# installed there would freeze at whatever version each qube first saw,
# while the unit file in /etc kept refreshing -- silent version skew.
/etc/qubes/qubes-firewall.d/50-wgq:
  file.managed:
    - source: salt://wgq/template/etc/qubes/qubes-firewall.d/50-wgq
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

/usr/sbin/wg-tunnel:
  file.managed:
    - source: salt://wgq/template/usr/sbin/wg-tunnel
    - user: root
    - group: root
    - mode: '0755'

/etc/systemd/system/wg-tunnel.service:
  file.managed:
    - source: salt://wgq/template/etc/systemd/system/wg-tunnel.service
    - user: root
    - group: root
    - mode: '0644'

wgq-systemd-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: /etc/systemd/system/wg-tunnel.service

# Enabled in the TEMPLATE, not in the qube: /etc is restored from the
# template on every AppVM boot, so `systemctl enable` inside a qube is lost.
# The unit no-ops in qubes without /rw/config/wg, so enabling it here is
# harmless for sys-fw-<zone> and any other qube on this template.
wg-tunnel.service:
  service.enabled:
    - require:
      - file: /etc/systemd/system/wg-tunnel.service
      - cmd: wgq-systemd-reload

/usr/bin/wgq:
  file.managed:
    - source: salt://wgq/dist/wgq
    - user: root
    - group: root
    - mode: '0755'
    # Built with `make` before applying this state. It is a zipapp, so
    # `unzip -p /usr/bin/wgq wgq/fwrules.py` reads the source back.

{% endif %}
