{#-
    wgq: the dom0 entrypoint on PATH.

    A symlink, deliberately, not a copy: the file that runs is always
    the one sitting in the airlocked tree under /srv/salt, so it can
    never drift from what `qubes-ingest status` verifies, and every
    approved pull updates the command in place.

        sudo wgq zone add            instead of typing the /srv/salt path
        wgq provision ...            framed into wgq-mgmt over qvm-run
        wgq switch <peer>            framed into the zone's VPN qube
-#}

wgq-cli-entrypoint:
  file.symlink:
    - name: /usr/local/bin/wgq
    - target: /srv/salt/wgq/dom0/wgq
    - force: True
