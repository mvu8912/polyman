FROM perl:5.38-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates git build-essential nodejs npm libperl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://raw.githubusercontent.com/Polymarket/polymarket-cli/main/install.sh | sh

WORKDIR /app

COPY cpanfile /app/cpanfile

RUN cpanm --notest --installdeps .

RUN apt update; apt install -y procps htop

CMD sleep infinity
