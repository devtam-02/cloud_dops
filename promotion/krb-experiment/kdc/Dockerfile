FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      krb5-kdc krb5-admin-server krb5-user ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 88/udp 88/tcp 749/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
