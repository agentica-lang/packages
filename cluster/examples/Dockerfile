# The image of the nodes of docker-compose.yml: a release of Agentica and the files of this package (it has no
# dependencies, so there is nothing to install). Build it from the folder of the package:
#   docker build -f examples/Dockerfile .
# The archive is checked against the sha256 of the release (the one in AGENTICA_VERSION for linux-x86_64); for another
# platform or version, pass the three ARGs together.
FROM debian:bookworm-slim
ARG AGENTICA_VERSION=0.39.1
ARG AGENTICA_PLATFORM=linux-x86_64
ARG AGENTICA_SHA256=c2ce2354068b82858917f049a38d3831f64a71d495b5237785aaf622d6d52725
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL -o /tmp/agentica.tar.gz \
        "https://github.com/agentica-lang/agentica/releases/download/${AGENTICA_VERSION}/agentica-${AGENTICA_VERSION}-${AGENTICA_PLATFORM}.tar.gz" \
    && echo "${AGENTICA_SHA256}  /tmp/agentica.tar.gz" | sha256sum -c - \
    && tar -xz -C /opt -f /tmp/agentica.tar.gz \
    && rm /tmp/agentica.tar.gz \
    && ln -s "/opt/agentica-${AGENTICA_VERSION}-${AGENTICA_PLATFORM}/bin/agentica" /usr/local/bin/agentica
WORKDIR /app
COPY . /app
RUN useradd --system --create-home node
USER node
CMD ["agentica", "examples/node.agc"]
