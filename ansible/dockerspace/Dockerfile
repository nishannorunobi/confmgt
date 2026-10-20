# ─────────────────────────────────────────────────────────────────────────────
# Dockerfile — confmgt's Ansible image: Python + pinned ansible-core + the ssh client + the agent's packages
#
# What for    Ansible runs in its own container (CONFMGT-3); the ansible-agent (the entry point) needs Python and its
#             packages. Built ONCE (needs the internet once), then the image is kept and every later start is offline.
#
# Who         docker compose (start.sh builds it when missing).
#
# How         bash start.sh                          (builds it when missing)
#             docker compose build ansible           (rebuild after a version / requirements change)
#
# Steps       1. FROM python:3-alpine pinned by digest (.env PYTHON_IMAGE + PYTHON_DIGEST)
#             2. + openssh-client (Ansible's transport) · bash + curl (the agent runs its own signup_with_kms.sh)
#             3. a venv in /opt/venv: ansible-core==<ANSIBLE_CORE_VERSION> + ansible-agent/requirements.txt
#
# Output      image confmgt-ansible:<ANSIBLE_CORE_VERSION>
#
# Next        docker compose up -d
# ─────────────────────────────────────────────────────────────────────────────
ARG PYTHON_IMAGE=python:3-alpine
ARG PYTHON_DIGEST=sha256:2e740b2c28a426e74f11396c05e38afb3191acced75045b8d62df573c1dc8ce8
FROM ${PYTHON_IMAGE}@${PYTHON_DIGEST}
ARG ANSIBLE_CORE_VERSION=2.21.5

# openssh-client: how Ansible reaches a machine · bash + curl: the agent's kms scripts run inside the container
RUN apk add --no-cache openssh-client bash curl \
 && python3 -m venv /opt/venv

COPY ansible-agent/requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-cache-dir "ansible-core==${ANSIBLE_CORE_VERSION}" -r /tmp/requirements.txt \
 && rm -f /tmp/requirements.txt
ENV PATH=/opt/venv/bin:$PATH
