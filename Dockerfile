FROM debian:bullseye-slim AS builder
RUN apt-get update && apt-get install -y \
pkg-config \
build-essential \
libssl-dev \
libzstd-dev \
wget \
curl \
libmariadb-dev && \
apt-get clean && \
rm -rf /var/lib/apt/lists/*
RUN curl https://raw.githubusercontent.com/tristanisham/zvm/master/install.sh | bash
RUN /bin/bash -c "source /root/.profile && zvm i master"
ENV PATH="${PATH}:/root/.zvm/bin"
RUN zig version
WORKDIR /build
CMD ["/bin/bash"]

FROM builder AS test
COPY ./build.zig .
COPY ./tests.zig .
COPY ./src ./src
RUN --mount=type=cache,target=/build/zig-cache zig build test
