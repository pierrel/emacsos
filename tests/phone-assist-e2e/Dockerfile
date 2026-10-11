FROM python:3.13-slim-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends \
    emacs-nox git openssh-client openssh-server openssl util-linux ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 test \
    && mkdir /runtime /state /state/threads /repos /secrets /home/test/.ssh \
    && chown -R test:test /runtime /state /repos /secrets /home/test/.ssh \
    && ln -s /runtime/workspace /workspace
COPY assist/pyproject.toml assist/requirements.txt /deps/
RUN python -c 'import tomllib; print("\n".join(tomllib.load(open("/deps/pyproject.toml", "rb"))["project"]["dependencies"]))' > /deps/runtime.txt \
    && pip install --no-cache-dir -r /deps/runtime.txt -c /deps/requirements.txt
COPY assist/ /src/assist/
COPY emacsos/ /src/emacsos/
RUN mkdir -p /src/assist/logs && chown test:test /src/assist/logs \
    && pip install --no-deps -e /src/assist
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/src/assist
WORKDIR /src/assist
USER test
CMD ["sleep", "300"]
