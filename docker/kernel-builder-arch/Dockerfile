FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Only packaging tools needed — kernel is already compiled
RUN apt-get update && apt-get install -y --no-install-recommends \
    libarchive-tools zstd \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /out/staging

# Pre-built artifacts are bind-mounted at /out/staging
# Output packages go to /out

COPY docker/kernel-builder-arch/build.sh /build.sh
RUN chmod +x /build.sh

CMD ["/build.sh"]
