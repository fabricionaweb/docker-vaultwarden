# syntax=docker/dockerfile:1-labs
FROM public.ecr.aws/docker/library/alpine:3.21 AS base
ENV TZ=UTC
WORKDIR /src

# source backend stage =========================================================
FROM base AS source-app

# get and extract source from git
ARG VERSION
ADD https://github.com/dani-garcia/vaultwarden/archive/refs/tags/$VERSION.tar.gz /tmp/source.tgz
RUN tar --strip-components=1 -xf /tmp/source.tgz

# backend stage =--=============================================================
FROM base AS build-backend
ENV CARGO_PROFILE_RELEASE_STRIP=symbols CARGO_PROFILE_RELEASE_PANIC=abort

# build dependencies
RUN apk add --no-cache cargo --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main && \
    apk add --no-cache sqlite-dev libpq-dev mimalloc2-dev

# build app
COPY --from=source-app /src/Cargo.* /src/build.rs ./
COPY --from=source-app /src/migrations ./migrations
COPY --from=source-app /src/macros ./macros
COPY --from=source-app /src/src ./src
ARG VERSION
ENV VW_VERSION=$VERSION
ARG FEATURES=sqlite,postgresql,enable_mimalloc
RUN cargo build --release --features $FEATURES

# frontend stage ===============================================================
FROM base AS build-frontend

# grab it pre-build from git (cant build this shit on alpine, it uses node-sass)
ARG VERSION_WEB
ADD https://github.com/dani-garcia/bw_web_builds/releases/download/v$VERSION_WEB/bw_web_v$VERSION_WEB.tar.gz /tmp/source.tgz
RUN tar --strip-components=1 -xf /tmp/source.tgz && \
    find ./ -name "*.map" -type f -delete

# runtime stage ================================================================
FROM base

ENV S6_VERBOSITY=0 S6_BEHAVIOUR_IF_STAGE2_FAILS=2 PUID=65534 PGID=65534
ENV DATA_FOLDER=/config WEB_VAULT_FOLDER=/app/web-vault
ENV EXTENDED_LOGGING=true LOG_FILE=/config/logs/vaultwarden.log
ENV ROCKET_ADDRESS=0.0.0.0 ROCKET_PORT=8000
WORKDIR /config
VOLUME /config
EXPOSE 8000

# copy files
COPY --from=build-backend /src/target/release/vaultwarden /app/
COPY --from=build-frontend /src /app/web-vault
COPY ./rootfs/. /

# runtime dependencies
RUN apk add --no-cache tzdata s6-overlay logrotate libgcc libpq curl

# run using s6-overlay
ENTRYPOINT ["/init"]
