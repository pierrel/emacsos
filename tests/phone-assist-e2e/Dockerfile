FROM python:3.13-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
    emacs-nox git openssh-client util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 test \
    && mkdir /runtime /secrets && chown test:test /runtime /secrets
COPY . /src/emacsos/
ENV PYTHONDONTWRITEBYTECODE=1 HOME=/home/test
WORKDIR /src/emacsos
USER test
