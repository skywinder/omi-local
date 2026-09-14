# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS node

FROM python:3.11.15-slim-trixie AS dependencies
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ git libffi-dev \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir uv==0.11.13
COPY backend/pylock.runtime.toml /tmp/pylock.runtime.toml
COPY docker/export_pins.py /tmp/export_pins.py
RUN python /tmp/export_pins.py /tmp/pylock.runtime.toml > /tmp/requirements.txt \
    && uv venv /opt/venv \
    && uv pip install --python /opt/venv/bin/python --no-deps -r /tmp/requirements.txt

FROM python:3.11.15-slim-trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg libopus0 libgomp1 libatomic1 redis-server openjdk-21-jre-headless lsof procps \
    && rm -rf /var/lib/apt/lists/*
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx
WORKDIR /opt/omiloc
COPY package.json package-lock.json /tmp/firebase/
RUN cd /tmp/firebase && npm ci --ignore-scripts --omit=optional \
    && mv node_modules /opt/omiloc/node_modules && rm -rf /tmp/firebase /root/.npm
ENV PATH="/opt/venv/bin:/opt/omiloc/node_modules/.bin:$PATH" \
    PYTHONPATH=/opt/omiloc/scripts/dev-harness \
    PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    FIREBASE_EMULATORS_PATH=/opt/firebase-emulators CI=true
RUN firebase setup:emulators:firestore
COPY --from=dependencies /opt/venv /opt/venv
COPY AGENTS.md firebase.json firestore.rules firestore.indexes.json ./
COPY --chown=10001:10001 backend/ backend/
COPY --chown=10001:10001 scripts/dev-harness/ scripts/dev-harness/
COPY web-local/ web-local/
COPY --chown=10001:10001 docker/ docker/
RUN useradd --create-home --uid 10001 omi && mkdir -p /data \
    && chown omi:omi /data /opt/omiloc /opt/firebase-emulators
USER omi
CMD ["python", "docker/runtime.py"]
