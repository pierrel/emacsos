#!/bin/sh
set -eu
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
docker run --rm --network none --user 0 \
    --mount "type=bind,src=$repo/deploy/pinephone,dst=/source,readonly" \
    --mount "type=bind,src=$repo/tests/test-pinephone-suspend-policy.py,dst=/test.py,readonly" \
    --entrypoint /bin/sh "${PINEPHONE_TEST_IMAGE:-assist-sandbox}" \
    -c 'useradd --system -M emacsos-lab; exec python3 /test.py -v'
