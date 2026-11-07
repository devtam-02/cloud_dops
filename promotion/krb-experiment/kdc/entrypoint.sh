#!/usr/bin/env bash
set -euo pipefail

REALM="${KRB5_REALM:?missing}"
DOMAIN="${KRB5_DOMAIN:?missing}"
KDC_HOST="${KDC_HOST:?missing}"
KAFKA_HOST="${KAFKA_HOST:?missing}"
MASTER_PW="${KDC_MASTER_PASSWORD:?missing}"
ADMIN_PW="${KDC_ADMIN_PASSWORD:?missing}"
CLIENT_PW="${CLIENT_PASSWORD:-ClientPassw0rd}"

SHARE_DIR=/krb          # volume dùng chung với kafka / kafka-ui / client
DB_DIR=/var/lib/krb5kdc # volume lưu database KDC

mkdir -p "$SHARE_DIR" "$DB_DIR" /etc/krb5kdc

# ------------------------------------------------------------------
# 1. krb5.conf  (dùng chung cho server lẫn client)
# ------------------------------------------------------------------
cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    forwardable = true
    renew_lifetime = 7d
    ticket_lifetime = 24h
    udp_preference_limit = 1
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}
    default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
    permitted_enctypes   = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
    ${REALM} = {
        kdc = ${KDC_HOST}
        admin_server = ${KDC_HOST}
    }

[domain_realm]
    .${DOMAIN} = ${REALM}
    ${DOMAIN} = ${REALM}

[logging]
    kdc = STDERR
    admin_server = STDERR
    default = STDERR
EOF

cat > /etc/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
    kdc_ports = 88
    kdc_tcp_ports = 88

[realms]
    ${REALM} = {
        database_name = ${DB_DIR}/principal
        admin_keytab = /etc/krb5kdc/kadm5.keytab
        acl_file = /etc/krb5kdc/kadm5.acl
        key_stash_file = ${DB_DIR}/.k5.${REALM}
        max_life = 24h 0m 0s
        max_renewable_life = 7d 0h 0m 0s
        supported_enctypes = aes256-cts-hmac-sha1-96:normal aes128-cts-hmac-sha1-96:normal
        default_principal_flags = +preauth
    }
EOF

echo '*/admin@'"${REALM}"' *' > /etc/krb5kdc/kadm5.acl

# ------------------------------------------------------------------
# 2. Khởi tạo database (chỉ lần đầu)
# ------------------------------------------------------------------
if [ ! -f "${DB_DIR}/principal" ]; then
    echo "[kdc] Creating KDC database for realm ${REALM} ..."
    kdb5_util create -r "${REALM}" -s -P "${MASTER_PW}"

    add_princ() {  # $1 = principal, $2 = password (bỏ trống => random key)
        if [ -n "${2:-}" ]; then
            kadmin.local -q "addprinc -pw $2 $1" >/dev/null
        else
            kadmin.local -q "addprinc -randkey $1" >/dev/null
        fi
        echo "[kdc]   + $1"
    }

    # --- admin của KDC
    add_princ "admin/admin@${REALM}" "${ADMIN_PW}"

    # --- Service principal của broker (host PHẢI khớp advertised.listeners)
    add_princ "kafka/${KAFKA_HOST}@${REALM}"

    # --- Principal cho Kafka UI và cho client/CLI
    add_princ "kafkaui@${REALM}"
    add_princ "kafkaclient@${REALM}"

    # --- Principal cho service promotion-ingestion
    add_princ "ingestion@${REALM}"

    # --- Principal người dùng, đăng nhập bằng mật khẩu (kinit alice)
    add_princ "alice@${REALM}" "${CLIENT_PW}"
    add_princ "bob@${REALM}"   "${CLIENT_PW}"

    echo "[kdc] Exporting keytabs to ${SHARE_DIR} ..."
    rm -f "${SHARE_DIR}"/*.keytab
    kadmin.local -q "ktadd -k ${SHARE_DIR}/kafka.keytab       kafka/${KAFKA_HOST}@${REALM}" >/dev/null
    kadmin.local -q "ktadd -k ${SHARE_DIR}/kafkaui.keytab     kafkaui@${REALM}"             >/dev/null
    kadmin.local -q "ktadd -k ${SHARE_DIR}/kafkaclient.keytab kafkaclient@${REALM}"         >/dev/null
    kadmin.local -q "ktadd -k ${SHARE_DIR}/ingestion.keytab   ingestion@${REALM}"             >/dev/null
    kadmin.local -q "ktadd -k /etc/krb5kdc/kadm5.keytab kadmin/admin kadmin/changepw"       >/dev/null
    chmod 644 "${SHARE_DIR}"/*.keytab
else
    echo "[kdc] Existing KDC database found, skipping bootstrap."
    [ -f /etc/krb5kdc/kadm5.keytab ] || \
        kadmin.local -q "ktadd -k /etc/krb5kdc/kadm5.keytab kadmin/admin kadmin/changepw" >/dev/null
fi

# ------------------------------------------------------------------
# 3. Phát krb5.conf + file JAAS ra volume dùng chung
# ------------------------------------------------------------------
cp /etc/krb5.conf "${SHARE_DIR}/krb5.conf"

cat > "${SHARE_DIR}/kafka_server_jaas.conf" <<EOF
KafkaServer {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    storeKey=true
    refreshKrb5Config=true
    keyTab="/krb/kafka.keytab"
    principal="kafka/${KAFKA_HOST}@${REALM}";
};
EOF

cat > "${SHARE_DIR}/kafka_client_jaas.conf" <<EOF
KafkaClient {
    com.sun.security.auth.module.Krb5LoginModule required
    useKeyTab=true
    storeKey=true
    refreshKrb5Config=true
    keyTab="/krb/kafkaclient.keytab"
    principal="kafkaclient@${REALM}";
};
EOF

cat > "${SHARE_DIR}/client.properties" <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=GSSAPI
sasl.kerberos.service.name=kafka
sasl.jaas.config=com.sun.security.auth.module.Krb5LoginModule required \\
    useKeyTab=true \\
    storeKey=true \\
    keyTab="/krb/kafkaclient.keytab" \\
    principal="kafkaclient@${REALM}";
EOF

chmod 644 "${SHARE_DIR}"/*.conf "${SHARE_DIR}"/*.properties
touch "${SHARE_DIR}/.ready"

echo "[kdc] Starting kadmind + krb5kdc ..."
kadmind -nofork &
KADMIN_PID=$!
krb5kdc -n &
KDC_PID=$!

trap 'kill -TERM $KADMIN_PID $KDC_PID 2>/dev/null || true' TERM INT
wait -n $KADMIN_PID $KDC_PID
