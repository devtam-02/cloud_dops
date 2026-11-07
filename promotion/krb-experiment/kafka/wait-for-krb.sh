#!/usr/bin/env bash
# Chờ KDC phát xong keytab + krb5.conf ra volume /krb rồi mới khởi động Kafka.
set -euo pipefail

TIMEOUT="${KRB_WAIT_TIMEOUT:-120}"
i=0
until [ -f /krb/.ready ] && [ -s /krb/kafka.keytab ] && [ -s /krb/krb5.conf ]; do
    i=$((i + 1))
    if [ "$i" -gt "$TIMEOUT" ]; then
        echo "FATAL: /krb chưa sẵn sàng sau ${TIMEOUT}s — kiểm tra log container kdc." >&2
        exit 1
    fi
    echo "waiting for Kerberos keytabs ... (${i}/${TIMEOUT})"
    sleep 1
done

echo "Kerberos artefacts ready:"
ls -l /krb
exec "$@"
