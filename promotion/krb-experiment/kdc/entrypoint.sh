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
# 2. Khởi tạo database + ĐẢM BẢO principal/keytab (idempotent)
#
# Cố ý KHÔNG gộp vào nhánh "database chưa tồn tại". Nếu chỉ tạo principal
# lúc khởi tạo lần đầu thì một volume kdc-db cũ (dựng bằng phiên bản
# entrypoint trước, khi chưa có principal `ingestion`) sẽ khiến bước này bị
# bỏ qua hoàn toàn: keytab không bao giờ được sinh ra, và client đọc nó sẽ
# lỗi khó hiểu "Could not login: the client is being asked for a password"
# — Krb5LoginModule không đọc được keytab nên rơi về hỏi mật khẩu.
# Chạy mỗi lần khởi động, chỉ tạo thứ còn thiếu, nên nâng cấp là tự lành.
# ------------------------------------------------------------------
if [ ! -f "${DB_DIR}/principal" ]; then
    echo "[kdc] Creating KDC database for realm ${REALM} ..."
    kdb5_util create -r "${REALM}" -s -P "${MASTER_PW}"
else
    echo "[kdc] Existing KDC database found; chỉ bổ sung thứ còn thiếu."
fi

princ_exists() {
    kadmin.local -q "getprinc $1" 2>/dev/null | grep -q "^Principal: $1"
}

# $1 = principal, $2 = mật khẩu (bỏ trống => khoá ngẫu nhiên), $3 = keytab (tuỳ chọn)
ensure_princ() {
    local princ="$1" pw="${2:-}" keytab="${3:-}"
    if princ_exists "$princ"; then
        :
    else
        if [ -n "$pw" ]; then
            kadmin.local -q "addprinc -pw $pw $princ" >/dev/null
        else
            kadmin.local -q "addprinc -randkey $princ" >/dev/null
        fi
        echo "[kdc]   + principal $princ"
        # Principal vừa tạo mang khoá mới => keytab cũ (nếu có) đã vô giá trị.
        [ -n "$keytab" ] && rm -f "$keytab"
    fi

    # Chỉ ktadd khi keytab thiếu: ktadd làm tăng kvno và vô hiệu hoá mọi bản
    # keytab đã phát ra trước đó, nên không chạy lại một cách vô cớ.
    if [ -n "$keytab" ] && [ ! -s "$keytab" ]; then
        kadmin.local -q "ktadd -k $keytab $princ" >/dev/null
        chmod 644 "$keytab"
        echo "[kdc]   + keytab    $keytab"
    fi
}

ensure_princ "admin/admin@${REALM}"            "${ADMIN_PW}"
# Service principal của broker (host PHẢI khớp advertised.listeners)
ensure_princ "kafka/${KAFKA_HOST}@${REALM}"    ""  "${SHARE_DIR}/kafka.keytab"
ensure_princ "kafkaui@${REALM}"                ""  "${SHARE_DIR}/kafkaui.keytab"
ensure_princ "kafkaclient@${REALM}"            ""  "${SHARE_DIR}/kafkaclient.keytab"
# Service promotion-ingestion
ensure_princ "ingestion@${REALM}"              ""  "${SHARE_DIR}/ingestion.keytab"
# Người dùng đăng nhập bằng mật khẩu (kinit alice)
ensure_princ "alice@${REALM}"                  "${CLIENT_PW}"
ensure_princ "bob@${REALM}"                    "${CLIENT_PW}"

[ -f /etc/krb5kdc/kadm5.keytab ] || \
    kadmin.local -q "ktadd -k /etc/krb5kdc/kadm5.keytab kadmin/admin kadmin/changepw" >/dev/null

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
