ARG ALPINE_VERSION

FROM alpine:${ALPINE_VERSION} AS build_erlang

# Important!  Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apk add` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT=2023-10-05 \
  LANG=C.UTF-8 \
  HOME=/app/ \
  TERM=xterm

# Add tagged repos as well as the edge repo so that we can selectively install edge packages
ARG ALPINE_VERSION
RUN set -xe \
  && ALPINE_MINOR_VERSION=$(echo ${ALPINE_VERSION} | cut -d'.' -f1,2) \
  && echo "@main http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR_VERSION}/main" >> /etc/apk/repositories \
  && echo "@community http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR_VERSION}/community" >> /etc/apk/repositories \
  && echo "@edge http://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories

# Upgrade Alpine and base packages
RUN set -xe \
  && apk --no-cache --update-cache --available upgrade

# Install bash and Erlang/OTP deps
RUN set -xe \
  && apk add --no-cache --update-cache --virtual .fetch-deps \
  bash \
  curl \
  ca-certificates \
  libgcc \
  lksctp-tools \
  pcre \
  zlib-dev

# Install Erlang/OTP build deps
RUN set -xe \
  && apk add --no-cache --virtual .build-deps \
  dpkg-dev \
  dpkg \
  gcc \
  g++ \
  libc-dev \
  linux-headers \
  make \
  autoconf \
  ncurses-dev \
  openssl-dev \
  unixodbc-dev \
  lksctp-tools-dev \
  tar

# Download OTP
ARG ERLANG_VERSION
ARG ERLANG_DOWNLOAD_SHA256
WORKDIR /tmp/erlang-build
RUN set -xe \
  && curl -fSL -o otp-src.tar.gz "https://github.com/erlang/otp/releases/download/OTP-${ERLANG_VERSION}/otp_src_${ERLANG_VERSION}.tar.gz" \
  && tar -xzf otp-src.tar.gz -C /tmp/erlang-build --strip-components=1 \
  # && sha256sum otp-src.tar.gz && exit 1 \
  && echo "${ERLANG_DOWNLOAD_SHA256}  otp-src.tar.gz" | sha256sum -c -

# Configure & Build
ARG ARCH
RUN set -xe \
  && export ERL_TOP=/tmp/erlang-build \
  && export CPPFLAGS="-D_BSD_SOURCE $CPPFLAGS" \
  && export gnuBuildArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
  && export gnuArch="$(dpkg-architecture --query DEB_HOST_GNU_TYPE)" \
  && ./configure \
  --build="$gnuBuildArch" \
  --host="$gnuArch" \
  --prefix=/usr/local \
  --sysconfdir=/etc \
  --mandir=/usr/share/man \
  --infodir=/usr/share/info \
  --without-javac \
  --without-jinterface \
  --without-wx \
  --without-debugger \
  --without-observer \
  --without-cosEvent \
  --without-cosEventDomain \
  --without-cosFileTransfer \
  --without-cosNotification \
  --without-cosProperty \
  --without-cosTime \
  --without-cosTransactions \
  --without-et \
  --without-gs \
  --without-ic \
  --without-megaco \
  --without-orber \
  --without-percept \
  --without-odbc \
  --without-typer \
  --enable-threads \
  --enable-shared-zlib \
  --enable-dynamic-ssl-lib \
  --enable-ssl=dynamic-ssl-lib \
  && $( \
  if [[ "${ARCH}" == *"amd64"* ]]; \
  then export CFLAGS="-g -O2 -fstack-clash-protection -fcf-protection=full"; \
  else export CFLAGS="-g -O2 -fstack-clash-protection"; fi \
  ) \
  && make -j$(getconf _NPROCESSORS_ONLN)

# Install to temporary location, stip the install, install runtime deps and copy to the final location
RUN set -xe \
  && make DESTDIR=/tmp install \
  && cd /tmp && rm -rf /tmp/erlang-build \
  && find /tmp/usr/local -regex '/tmp/usr/local/lib/erlang/\(lib/\|erts-\).*/\(man\|doc\|obj\|c_src\|emacs\|info\|examples\)' | xargs rm -rf \
  && find /tmp/usr/local -name src | xargs -r find | grep -v '\.hrl$' | xargs rm -v || true \
  && find /tmp/usr/local -name src | xargs -r find | xargs rmdir -vp || true \
  # Strip install to reduce size
  && scanelf --nobanner -E ET_EXEC -BF '%F' --recursive /tmp/usr/local | xargs -r strip --strip-all \
  && scanelf --nobanner -E ET_DYN -BF '%F' --recursive /tmp/usr/local | xargs -r strip --strip-unneeded \
  && runDeps="$( \
  scanelf --needed --nobanner --format '%n#p' --recursive /tmp/usr/local \
  | tr ',' '\n' \
  | sort -u \
  | awk 'system("[ -e /tmp/usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
  )" \
  && ln -s /tmp/usr/local/lib/erlang /usr/local/lib/erlang \
  && /tmp/usr/local/bin/erl -eval "beam_lib:strip_release('/tmp/usr/local/lib/erlang/lib')" -s init stop > /dev/null \
  && (/usr/bin/strip /tmp/usr/local/lib/erlang/erts-*/bin/* || true) \
  && apk add --no-cache --virtual .erlang-runtime-deps $runDeps lksctp-tools ca-certificates

# Cleanup after Erlang install
RUN set -xe \
  && apk del .fetch-deps .build-deps \
  && cd /tmp \
  && rm -rf /tmp/erlang-build \
  && rm -rf /var/cache/apk/*

WORKDIR ${HOME}

CMD ["erl"]

FROM alpine:${ALPINE_VERSION} AS build_elixir

ENV LANG=C.UTF-8 \
  HOME=/app/ \
  TERM=xterm

# Add tagged repos as well as the edge repo so that we can selectively install edge packages
ARG ALPINE_VERSION
RUN set -xe \
  && ALPINE_MINOR_VERSION=$(echo ${ALPINE_VERSION} | cut -d'.' -f1,2) \
  && echo "@main http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR_VERSION}/main" >> /etc/apk/repositories \
  && echo "@community http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR_VERSION}/community" >> /etc/apk/repositories \
  && echo "@edge http://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories

# Erlang run deps
RUN set -xe \
  # Upgrade Alpine and base packages
  && apk --no-cache --update-cache --available upgrade \
  # Install bash, Erlang/OTP and Elixir deps
  && apk add --no-cache --update-cache \
  libstdc++ \
  ca-certificates \
  ncurses \
  openssl \
  pcre \
  unixodbc \
  zlib \
  # Update ca certificates
  && update-ca-certificates --fresh

# Install Elixir build deps
RUN set -xe \
  && apk add --no-cache --virtual .build-deps \
  make \
  bash \
  curl \
  tar \
  ca-certificates

# Download Elixir
ARG ELIXIR_VERSION
ARG ELIXIR_DOWNLOAD_SHA256
WORKDIR /tmp/elixir-build
RUN set -xe \
  && curl -fSL -o elixir-src.tar.gz "https://github.com/elixir-lang/elixir/archive/v${ELIXIR_VERSION}.tar.gz" \
  && mkdir -p /tmp/usr/local/src/elixir \
  && tar -xzC /tmp/usr/local/src/elixir --strip-components=1 -f elixir-src.tar.gz \
  # && sha256sum elixir-src.tar.gz && exit 1 \
  && echo "${ELIXIR_DOWNLOAD_SHA256}  elixir-src.tar.gz" | sha256sum -c - \
  && rm elixir-src.tar.gz

COPY --from=build_erlang /tmp/usr/local /usr/local

# Compile Elixir
RUN set -xe \
  && cd /tmp/usr/local/src/elixir \
  && make DESTDIR=/tmp install clean \
  && find /tmp/usr/local/src/elixir/ -type f -not -regex "/tmp/usr/local/src/elixir/lib/[^\/]*/lib.*" -exec rm -rf {} + \
  && find /tmp/usr/local/src/elixir/ -type d -depth -empty -delete \
  && rm -rf /tmp/elixir-build \
  && apk del .build-deps

# Cleanup apk cache
RUN rm -rf /var/cache/apk/*

WORKDIR ${HOME}

CMD ["iex"]

FROM alpine:${ALPINE_VERSION} as release

ENV LANG=C.UTF-8 \
  HOME=/app/ \
  TERM=xterm

ARG ALPINE_VERSION
RUN set -xe \
  && ALPINE_MINOR_VERSION=$(echo ${ALPINE_VERSION} | cut -d'.' -f1,2) \
  && echo "@main http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR_VERSION}/main" >> /etc/apk/repositories \
  && echo "@community http://dl-cdn.alpinelinux.org/alpine/v${ALPINE_MINOR_VERSION}/community" >> /etc/apk/repositories \
  && echo "@edge http://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories

RUN set -xe \
  # Upgrade Alpine and base packages
  && apk --no-cache --update-cache --available upgrade \
  # Install bash, Erlang/OTP and Elixir deps
  && apk add --no-cache --update-cache \
  bash \
  libstdc++ \
  ca-certificates \
  ncurses \
  openssl \
  pcre \
  unixodbc \
  zlib \
  # Update ca certificates
  && update-ca-certificates --fresh

WORKDIR ${HOME}

# Copy Erlang/OTP and Elixir installations
COPY --from=build_erlang /tmp/usr/local /usr/local
COPY --from=build_elixir /tmp/usr/local /usr/local

# Install hex + rebar
ONBUILD RUN set -xe \
  && mix local.hex --force \
  && mix local.rebar --force

CMD ["bash"]
