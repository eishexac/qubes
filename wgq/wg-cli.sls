{#-
    wgq: the dom0 entrypoint on PATH.

    A symlink, deliberately, not a copy: the file that runs is always
    the one sitting in the airlocked tree under /srv/salt, so it can
    never drift from what `qubes-ingest status` verifies, and every
    approved pull updates the command in place.

    That choice makes `sudo` part of the command: /srv/salt is
    root-only on Qubes (0750), so a user shell cannot even stat the
    symlink's target -- PATH lookup skips it and reports the command
    as not found. Correct, not a bug: the tree the airlock approved
    stays root's, and every wgq verb is dom0 authority anyway. The
    canonical spelling everywhere is `sudo wgq ...`.

        sudo wgq zone add            instead of typing the /srv/salt path
        sudo wgq provision ...       framed into wgq-mgmt over qvm-run
        sudo wgq switch <peer>       framed into the zone's VPN qube
-#}

wgq-cli-entrypoint:
  file.symlink:
    - name: /usr/local/bin/wgq
    - target: /srv/salt/wgq/dom0/wgq
    - force: True
