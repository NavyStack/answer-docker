FROM node:lts-bookworm AS git

ARG TARGETARCH
ARG PLUGIN_LIST_FILE=/incubator-answer/script/plugin_list

WORKDIR /incubator-answer/
RUN git clone --recurse-submodules -j8 --depth 1 \
    https://github.com/apache/incubator-answer.git /incubator-answer/

RUN case "$TARGETARCH" in \
        "arm") \
            PLUGIN_LIST="github.com/apache/incubator-answer-plugins/connector-basic@latest \
                         github.com/apache/incubator-answer-plugins/connector-github@latest \
                         github.com/apache/incubator-answer-plugins/editor-formula@latest";; \
        "amd64"|"arm64") \
            PLUGIN_LIST="github.com/apache/incubator-answer-plugins/connector-basic@latest \
                         github.com/apache/incubator-answer-plugins/connector-github@latest \
                         github.com/apache/incubator-answer-plugins/storage-s3@latest \
                         github.com/apache/incubator-answer-plugins/editor-chart@latest \
                         github.com/apache/incubator-answer-plugins/editor-formula@latest \
                         github.com/apache/incubator-answer-plugins/cache-redis@latest";; \
        *) \
            echo "Unsupported architecture: $TARGETARCH" && \
            exit 1;; \
    esac && \
    if [ ! -f "$PLUGIN_LIST_FILE" ]; then \
        echo "Plugin list file '$PLUGIN_LIST_FILE' not found. Exiting."; \
        exit 1; \
    fi && \
    { \
        cat "$PLUGIN_LIST_FILE"; \
        echo "$PLUGIN_LIST"; \
    } | sort | uniq > "$PLUGIN_LIST_FILE"

FROM node:lts-bookworm AS golang-builder

ARG TARGETARCH
ARG GOLANG_VERSION=1.22.0
ARG CGO_EXTRA_CFLAGS

ENV PNPM_HOME="/pnpm"
ENV GOPATH="/go"
ENV GOROOT="/usr/local/go"
ENV PACKAGE="github.com/apache/incubator-answer"
ENV PATH="$PNPM_HOME:$GOPATH/bin:$GOROOT/bin:$PATH"
ENV BUILD_DIR ${GOPATH}/src/${PACKAGE}
ENV ANSWER_MODULE ${BUILD_DIR}

COPY --from=git /incubator-answer/ ${BUILD_DIR}

WORKDIR ${BUILD_DIR}
RUN case "$TARGETARCH" in \
        "arm") \
            GO_PKG="go${GOLANG_VERSION}.linux-${TARGETARCH}v6l.tar.gz" && \
            wget https://go.dev/dl/$GO_PKG && \
            tar -C /usr/local -xzf $GO_PKG && \
            rm $GO_PKG && \
            corepack enable && \
            export NODE_OPTIONS="--max-old-space-size=8096" && \
            pnpm add -D -r @swc/core-linux-arm-gnueabihf @swc/core @swc/cli @swc/wasm swc-loader;; \
        "amd64"|"arm64") \
            GO_PKG="go${GOLANG_VERSION}.linux-${TARGETARCH}.tar.gz" && \
            wget https://go.dev/dl/$GO_PKG && \
            tar -C /usr/local -xzf $GO_PKG && \
            rm $GO_PKG && \
            corepack enable ;; \
        *) \
            echo "Unsupported architecture: $TARGETARCH" && \
            exit 1 ;; \
    esac && \
    make clean build

RUN chmod +x answer
RUN ["/bin/bash","-c","script/build_plugin.sh"]
RUN cp answer /usr/bin/answer

RUN mkdir -p /data/uploads \
        && chmod 777 /data/uploads \
    && mkdir -p /data/i18n \
        && cp -r i18n/*.yaml /data/i18n

FROM debian:bookworm-slim AS final
LABEL maintainer=github.com/NavyStack/answer-docker

ENV TIMEZONE="Asia/Seoul" \
    USER="answer" \
    UID="1001" \
    GID="1001"

RUN groupadd --gid $GID $USER \
  && useradd --uid $UID --gid $GID --home-dir /data/ --shell /bin/bash $USER \
  && mkdir -p /data/ \
  && chown -R $USER:$USER /data/ \
  && apt-get update \
    && DEBIAN_FRONTEND=noninteractive \
        apt-get -y --no-install-recommends install \
            ca-certificates \
            curl \
            tini \
            gettext \
            openssh-client \
            sqlite3 \
            gnupg \
            tzdata \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
  && ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime \
  && echo "$TIMEZONE" > /etc/timezone

COPY --from=golang-builder --chown=$USER:$USER /usr/bin/answer /usr/bin/answer
COPY --from=golang-builder --chown=$USER:$USER /data /data
COPY --from=git --chown=$USER:$USER /incubator-answer/script/entrypoint.sh /entrypoint.sh

WORKDIR /data
USER $USER

VOLUME /data
EXPOSE 80

ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
