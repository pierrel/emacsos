FROM alpine:3.22
COPY source/deploy/pinephone/openrc-runtime /tmp/openrc-runtime
RUN . /tmp/openrc-runtime && apk add --no-cache $runtime_packages alpine-base linux-virt openrc openssh eudev eudev-openrc \
    python3 dbus dbus-openrc \
    mesa-dri-gallium fontconfig ttf-dejavu dtach e2fsprogs \
    build-base qemu-system-x86_64 qemu-img openssh-client cairo-dev pango-dev wayland-dev libxkbcommon-dev scdoc
COPY keyboard.tar /tmp/keyboard.tar
RUN mkdir /tmp/keyboard && tar xf /tmp/keyboard.tar -C /tmp/keyboard && \
    make -C /tmp/keyboard BIN=wvkbd-emacsos LAYOUT=mobintl && \
    install -m755 /tmp/keyboard/wvkbd-emacsos /usr/local/bin/wvkbd-emacsos && \
    mkdir -p /usr/local/share/licenses/wvkbd-emacsos && \
    install -m644 /tmp/keyboard/THIRD_PARTY_LICENSES.md /usr/local/share/licenses/wvkbd-emacsos/wordninja.txt && \
    rm -rf /tmp/keyboard /tmp/keyboard.tar
COPY source/ /source/
# Use only the native architecture-neutral browser policy from signed v25.06.
# The tagged repository and its signing key are scoped to these APK operations.
RUN set -eu; . /tmp/openrc-runtime; \
    key=/source/deploy/virtual-phone/build.postmarketos.org.rsa.pub; \
    printf '%s  %s\n' "$browser_policy_key_sha256" "$key" | sha256sum -c -; \
    mkdir /tmp/policy-keys; cp /etc/apk/keys/* /tmp/policy-keys/; \
    install -m0644 "$key" /tmp/policy-keys/build.postmarketos.org.rsa.pub; \
    apk --keys-dir /tmp/policy-keys --repository "@pmos $browser_policy_repository" update; \
    set --; for package in $browser_policy_packages; do set -- "$@" "$package@pmos"; done; \
    apk --keys-dir /tmp/policy-keys --repository "@pmos $browser_policy_repository" add "$@"; \
    apk --no-network add $browser_policy_packages; \
    rm -rf /tmp/policy-keys /tmp/openrc-runtime
RUN /source/deploy/virtual-phone/provision

RUN apk add --no-cache qemu-hw-display-virtio-vga
