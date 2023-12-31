# syntax=docker/dockerfile:1-labs
FROM public.ecr.aws/docker/library/alpine:3.19 AS base
ENV TZ=UTC
WORKDIR /src

# source backend stage =========================================================
FROM base AS source-app

# get and extract source from git
ARG VERSION
ADD https://github.com/dani-garcia/vaultwarden.git#$VERSION ./

# source web stage =============================================================
FROM base AS source-web

# get and extract source (vaultwarden patched) from git
ARG VERSION_WEB
ADD https://github.com/dani-garcia/bw_web_builds.git#v$VERSION_WEB ./

# backend stage =--=============================================================
FROM base AS build-backend
ENV CARGO_PROFILE_RELEASE_STRIP=symbols CARGO_PROFILE_RELEASE_PANIC=abort

# build dependencies
RUN apk add --no-cache cargo sqlite-dev libpq-dev mimalloc2-dev

# dummy project to build dependencies
RUN mkdir ./src ./.cargo && \
    echo -e "fn main() { println!(\"Hello, world!\"); }" > ./src/main.rs

# build dependencies
COPY --from=source-app /src/Cargo.* /src/build.rs ./
ARG FEATURES=sqlite,postgresql,enable_mimalloc
RUN cargo build --release --features $FEATURES --locked

# build app
COPY --from=source-app /src/migrations ./migrations
COPY --from=source-app /src/src ./src
ARG VERSION
ENV VW_VERSION=$VERSION
RUN cargo build --release --features $FEATURES --frozen

# patch frontend stage =========================================================
FROM base AS patch-frontend

# dependencies
RUN apk add --no-cache git bash

# get and extract source (bitwarden) from git
ARG VERSION_WEB
ADD https://github.com/bitwarden/clients.git#web-v$VERSION_WEB ./web-vault

# prepare project with patches
COPY --from=source-web /src/patches ./patches
COPY --from=source-web /src/resources ./resources
COPY --from=source-web /src/scripts/.script_env /src/scripts/apply_patches.sh \
        /src/scripts/patch_web_vault.sh ./scripts/
RUN ./scripts/patch_web_vault.sh

# create a temporary folder to all package.json (for the workspace tree)
RUN bash -O globstar -c 'cp --verbose --parents ./**/package*.json /tmp'

# frontend stage ===============================================================
FROM base AS build-frontend

# build dependencies
RUN apk add --no-cache build-base python3 git nodejs-current && corepack enable npm

# node_modules
COPY --from=patch-frontend /src/web-vault/tsconfig.json /src/web-vault/tailwind.config.js /src/web-vault/angular.json ./
COPY --from=patch-frontend /tmp/web-vault/. ./
RUN npm ci --fund=false --audit=false --ignore-scripts

# frontend source and build
COPY --from=patch-frontend /src/web-vault/bitwarden_license ./bitwarden_license
COPY --from=patch-frontend /src/web-vault/libs ./libs
COPY --from=patch-frontend /src/web-vault/apps/web ./apps/web
RUN cd ./apps/web && \
    npm run dist:oss:selfhost && \
    find ./build -name "*.map" -type f -delete

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
COPY --from=build-frontend /src/apps/web/build /app/web-vault
COPY ./rootfs/. /

# runtime dependencies
RUN apk add --no-cache tzdata s6-overlay logrotate libgcc libpq curl

# run using s6-overlay
ENTRYPOINT ["/init"]
