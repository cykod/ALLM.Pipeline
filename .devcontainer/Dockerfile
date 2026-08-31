# Same base + kerl build deps as ~/Projects/ALLM and the Amesbury umbrella so
# the erlang-asdf feature compiles OTP the same way in all three. No Playwright
# here — this package has no browser surface — and no AWS CLI: the artifact
# stack (DynamoDB Local, MinIO) is reached over HTTP with static minio creds.
FROM mcr.microsoft.com/devcontainers/base:noble

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      autoconf \
      m4 \
      libncurses-dev \
      libssl-dev \
      libssh-dev \
      unixodbc-dev \
      libgmp-dev \
      libffi-dev \
      libyaml-dev \
      libreadline-dev \
      xsltproc \
      fop \
      libxml2-utils \
      curl \
      git \
      postgresql-client \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*
