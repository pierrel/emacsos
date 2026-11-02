#!/bin/sh
set -eu
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --network none --cap-add SYS_PTRACE --cap-add BLOCK_SUSPEND \
    --mount "type=bind,src=$repo_dir/deploy/pinephone/openrc-power-monitor,dst=/source/openrc-power-monitor,readonly" \
    --mount "type=bind,src=$repo_dir/deploy/pinephone/emacsos-ui.initd,dst=/source/emacsos-ui.initd,readonly" \
    --mount "type=bind,src=$repo_dir/tests/test-pinephone-native-input.py,dst=/test.py,readonly" \
    --mount "type=bind,src=$repo_dir/deploy/pinephone/openrc-call-root,dst=/helper,readonly" \
    --mount "type=bind,src=$repo_dir/tests/test-pinephone-call-idle.py,dst=/call-test.py,readonly" \
    python:3.13-alpine /bin/sh -ec '
        addgroup -S emacsos-lab
        adduser -S -D -H -G emacsos-lab emacsos-lab
        ln -s /usr/local/bin/python3 /usr/bin/python3
        python3 /test.py
        printf "#!/bin/sh\nexit 0\n" >/usr/bin/mmcli
        chmod 0755 /usr/bin/mmcli
        exec python3 /call-test.py
    '
