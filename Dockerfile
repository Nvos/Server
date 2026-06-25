# syntax=docker/dockerfile:1
#
# TAK Server — build from a LOCAL git clone of TAK-Product-Center/Server.
# Single container (config + messaging + api + plugin-manager). LOCAL / DEV use.
#
# IMPORTANT: build from a `git clone` of the repo, NOT a downloaded ZIP. The TAK
# build derives its version from `git describe`, so the .git directory + tags must
# be present. Put these docker files in the repo root (next to src/), and make sure
# .dockerignore does NOT exclude .git.
#
# Select the release with --build-arg TAK_REF=<tag> (default below). To build your
# OWN modified working tree instead, see the note on the checkout line.

##############################################################################
# Stage 1 — build with Gradle (Java 17) from the copied-in clone
##############################################################################
FROM eclipse-temurin:17-jdk-jammy AS builder

ARG TAK_REF=5.7-RELEASE-14

RUN apt-get update && \
    apt-get install -y --no-install-recommends git ca-certificates patch && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build/repo
# Copy your local clone (the .git dir comes along — that's the whole point).
COPY . /build/repo/

# Check out the requested release and force an annotated tag at HEAD so
# grgit's `git describe` resolves to a clean version string. Local git ops = fast.
#   To build your own modifications instead: delete the `git checkout` line and
#   commit your changes first (the force-tag below keeps `describe` working).
RUN git config --global user.email "build@takserver.local"
RUN git config --global user.name "TAK Docker Build"
RUN git config --global --add safe.directory /build/repo
RUN git checkout -B build main
RUN git tag -f -a "${TAK_REF}" -m "docker build"
RUN git describe

WORKDIR /build/repo/src
# Gradle cache mount: downloaded deps + the wrapper survive across rebuilds, so
# only the FIRST build pays the download cost. (Requires BuildKit — default in
# modern Docker / Docker Desktop.)  Add -Dorg.gradle.jvmargs=-Xmx3g if it OOMs.
RUN --mount=type=cache,target=/root/.gradle \
    chmod +x ./gradlew && \
    ./gradlew --no-daemon clean bootWar bootJar shadowJar

# Assemble the exact /opt/tak layout the official docker entrypoint expects.
RUN set -eux; \
    mkdir -p /staging/tak/db-utils /staging/tak/utils; \
    cp "$(ls takserver-core/build/libs/takserver-core-*.war | grep -v -- -plain | head -n1)" \
        /staging/tak/takserver.war; \
    cp "$(ls takserver-plugin-manager/build/libs/takserver-plugin-manager-*.jar | grep -v -- -plain | head -n1)" \
        /staging/tak/takserver-pm.jar; \
    cp takserver-schemamanager/build/libs/schemamanager-*-uber.jar /staging/tak/db-utils/SchemaManager.jar; \
    cp takserver-usermanager/build/libs/UserManager-*-all.jar      /staging/tak/utils/UserManager.jar; \
    cp takserver-core/scripts/setenv.sh                            /staging/tak/setenv.sh; \
    cp -R takserver-core/scripts/certs                             /staging/tak/certs; \
    cp takserver-core/example/CoreConfig.xml                      /staging/tak/CoreConfig.xml; \
    cp takserver-core/example/TAKIgniteConfig.example.xml         /staging/tak/TAKIgniteConfig.example.xml; \
    cp takserver-core/docker/full/docker_entrypoint.sh            /staging/tak/docker_entrypoint.sh; \
    cp takserver-core/docker/full/coreConfigEnvHelper.py          /staging/tak/coreConfigEnvHelper.py

##############################################################################
# Stage 2 — slim runtime
##############################################################################
FROM eclipse-temurin:17-jammy

# openssl -> CA / cert generation; python3+lxml -> coreConfigEnvHelper.py.
# keytool ships with the Temurin JDK image.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        openssl python3 python3-lxml ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /staging/tak /opt/tak
WORKDIR /opt/tak
RUN chmod +x /opt/tak/docker_entrypoint.sh /opt/tak/setenv.sh /opt/tak/certs/*.sh

# 8089 client TLS | 8443 admin UI | 8446 WebTAK/enrollment | 8444/9000/9001 federation
EXPOSE 8089 8443 8444 8446 9000 9001

ENTRYPOINT ["/bin/bash", "/opt/tak/docker_entrypoint.sh"]