# The image of the nodes of docker-compose.yml: a release of Agentica and the files of this package.
# Build it from the folder of the package: docker build -f examples/Dockerfile .
FROM debian:bookworm-slim
ARG AGENTICA_VERSION=0.39.1
ARG AGENTICA_PLATFORM=linux-x86_64
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://github.com/agentica-lang/agentica/releases/download/${AGENTICA_VERSION}/agentica-${AGENTICA_VERSION}-${AGENTICA_PLATFORM}.tar.gz" \
        | tar -xz -C /opt \
    && ln -s "/opt/agentica-${AGENTICA_VERSION}-${AGENTICA_PLATFORM}/bin/agentica" /usr/local/bin/agentica
WORKDIR /app
COPY . /app
CMD ["agentica", "examples/node.agc"]
