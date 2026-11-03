# Build on the official Swift image, run on its slim variant (Foundation's libraries, no compiler).
FROM swift:6.2-noble AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --product cool-reader-server \
    && cp "$(swift build -c release --show-bin-path)/cool-reader-server" /usr/local/bin/

FROM swift:6.2-noble-slim
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates tzdata && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/cool-reader-server /usr/local/bin/cool-reader-server
ENV COOLREADER_CONFIG=/config
VOLUME /config
EXPOSE 7272
ENTRYPOINT ["cool-reader-server"]
