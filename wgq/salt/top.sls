{#-
    wgq top file.

    Qubes' top.enable expects this at /srv/salt/wgq.top rather than under
    the formula directory, so install it as:

        sudo cp salt/top.sls /srv/salt/wgq.top
        sudo qubesctl top.enable wgq

    Or skip top.enable entirely and apply the states by name, which is
    clearer about what runs where and is what the README does:

        sudo qubesctl --show-output state.apply wgq.wg-template
        sudo qubesctl --skip-dom0 --targets=wgq-debian-13 --show-output \
            state.apply wgq.wg-template
        sudo qubesctl --show-output state.apply wgq.wg-qubes
-#}

{% set tpl = salt['pillar.get']('wgq:template', 'wgq-debian-13') %}

base:
  dom0:
    - wgq.wg-template
    - wgq.wg-qubes
  '{{ tpl }}':
    - wgq.wg-template
