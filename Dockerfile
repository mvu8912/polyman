FROM perl:5.38-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates git build-essential nodejs npm \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g polymarket

WORKDIR /app
COPY cpanfile /app/cpanfile
RUN cpanm --notest --installdeps .

COPY lib /app/lib
COPY bin /app/bin
RUN chmod +x /app/bin/*.pl

VOLUME ["/data"]
ENV STATE_FILE=/data/manager-state.json

CMD ["perl", "/app/bin/manager.pl"]
