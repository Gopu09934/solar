FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    curl \
    ca-certificates \
    bash \
    coreutils \
    findutils \
    fontconfig \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY . /app/

# Fix Windows CRLF line endings
RUN sed -i 's/\r$//' /app/start.sh

# Make script executable
RUN chmod 755 /app/start.sh

# Explicitly run through bash
ENTRYPOINT ["/bin/bash", "/app/start.sh"]
