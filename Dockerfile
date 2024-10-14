FROM debian:bullseye-slim AS builder
RUN apt-get update && apt-get install -y \
pkg-config \
build-essential \
wget \
curl \
libmariadb-dev && \
apt-get clean && \
rm -rf /var/lib/apt/lists/*

RUN curl https://raw.githubusercontent.com/tristanisham/zvm/master/install.sh | bash
SHELL ["/bin/bash", "-c"]
RUN /bin/bash -c "source /root/.profile && zvm i master"
ENV PATH="${PATH}:/root/.zvm/bin"
RUN zig version
RUN apt-get update && apt-get install -y \
libssl-dev \
libzstd-dev
RUN pkg-config --cflags --libs mariadb
WORKDIR /build

COPY ./build.zig .
COPY ./tests.zig .
COPY ./src ./src
RUN --mount=type=cache,target=/build/zig-cache zig build test
