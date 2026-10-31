#!/bin/sh
set -eu
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
provider=${ELOGIND_PROOF_BUILD_DIR:?set ELOGIND_PROOF_BUILD_DIR to the reviewed native fixture build}
docker run --rm --user 0 --network none --cap-add SYS_PTRACE --cap-add BLOCK_SUSPEND \
    --entrypoint /bin/sh \
    --mount "type=bind,src=$repo_dir/deploy/pinephone,dst=/source,readonly" \
    --mount "type=bind,src=$provider,dst=/native,readonly" \
    --mount "type=bind,src=$repo_dir/tests/test-pinephone-native-input.py,dst=/input-test.py,readonly" \
    --mount "type=bind,src=$repo_dir/tests/test-pinephone-native-sleep.py,dst=/proof.py,readonly" \
    --mount "type=bind,src=$repo_dir/tests/elogind-native-proof/counter.py,dst=/counter.py,readonly" \
    "${ELOGIND_PROOF_IMAGE:-assist-sandbox}" \
    -c 'useradd --system -M emacsos-lab; exec python3 /proof.py'
