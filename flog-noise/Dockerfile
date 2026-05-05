FROM golang:1.22-bookworm AS builder

RUN git clone --depth 1 --branch v0.4.3 https://github.com/mingrammer/flog.git /src \
    && cd /src \
    && go build -o /flog


FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        rsyslog \
        procps \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH \
        | gpg --no-default-keyring --keyring /usr/share/keyrings/wazuh.gpg --import \
    && chmod 644 /usr/share/keyrings/wazuh.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list \
    && apt-get update \
    && WAZUH_MANAGER='wazuh.manager' \
       apt-get install -y --no-install-recommends wazuh-agent=4.14.4-1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /flog /usr/local/bin/flog

COPY localfile-additions.xml /tmp/localfile-additions.xml
RUN cat /tmp/localfile-additions.xml >> /var/ossec/etc/ossec.conf \
    && rm /tmp/localfile-additions.xml

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
