{#-
    wgq: identity -- labels and icons.

    Qubes resolves every qube's icon name as <class>-<label-name> and its
    window border colour from the label. Labels are not limited to the
    stock eight: admin.label.Create makes NAMED labels with any colour,
    and a service qube labelled 'wgq' resolves the icon 'servicevm-wgq'
    -- a name no stock qube can ever wear. So wgq shadows no stock icon
    file and claims no stock label; it brings its own, coloured to follow
    the system's own grammar:

        wgq       0xCC0000  red, like sys-net    -- the edge (VPN qubes)
        wgq-fw    0x73D216  green, like sys-firewall -- the filter
        wgq-mgmt  0xEDD400  yellow               -- the provisioning qube
        wgq-tpl   0x000000  black, like stock templates -- the template

    The icon files land in /usr/share/icons -- the one base dir every
    GUI process searches unconditionally (dom0 sessions do not reliably
    put /usr/local/share on XDG_DATA_DIRS, and a name the theme cannot
    resolve renders as a BLANK icon in the 4.3 menu). The files are
    unowned by any package, so system updates leave them alone. The GUI
    picks them up after the cache refresh, at the latest on the next
    login. wg-zone and wg-mgmt include this state, so a skipped apply
    step only defers it to the first zone or mgmt run.

    qubesd-query is used because no qvm-* tool wraps label creation; the
    command is deliberately spelled out here where it can be read.
-#}

wgq-label-wgq:
  cmd.run:
    - name: printf '0xCC0000' | qubesd-query --fail dom0 admin.label.Create dom0 wgq
    - unless: qubesd-query --fail -e dom0 admin.label.Get dom0 wgq

wgq-label-wgq-fw:
  cmd.run:
    - name: printf '0x73D216' | qubesd-query --fail dom0 admin.label.Create dom0 wgq-fw
    - unless: qubesd-query --fail -e dom0 admin.label.Get dom0 wgq-fw

wgq-label-wgq-mgmt:
  cmd.run:
    - name: printf '0xEDD400' | qubesd-query --fail dom0 admin.label.Create dom0 wgq-mgmt
    - unless: qubesd-query --fail -e dom0 admin.label.Get dom0 wgq-mgmt

wgq-label-wgq-tpl:
  cmd.run:
    - name: printf '0x000000' | qubesd-query --fail dom0 admin.label.Create dom0 wgq-tpl
    - unless: qubesd-query --fail -e dom0 admin.label.Get dom0 wgq-tpl

{% for icon in ['servicevm-wgq.svg', 'servicevm-wgq-fw.svg', 'appvm-wgq.svg', 'appvm-wgq-fw.svg', 'appvm-wgq-mgmt.svg', 'templatevm-wgq-tpl.svg'] %}
wgq-icon-{{ icon }}:
  file.managed:
    - name: /usr/share/icons/hicolor/scalable/apps/{{ icon }}
    - source: salt://wgq/dom0/icons/{{ icon }}
    - makedirs: True
    - mode: '0644'
{% endfor %}

# Best effort: icon lookup works from the plain directory too, so a
# failed cache rebuild must not fail the install.
wgq-icon-cache:
  cmd.run:
    - name: gtk-update-icon-cache -f -t /usr/share/icons/hicolor || true
    - onchanges:
{% for icon in ['servicevm-wgq.svg', 'servicevm-wgq-fw.svg', 'appvm-wgq.svg', 'appvm-wgq-fw.svg', 'appvm-wgq-mgmt.svg', 'templatevm-wgq-tpl.svg'] %}
      - file: wgq-icon-{{ icon }}
{% endfor %}
