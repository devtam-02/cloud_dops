#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Khởi tạo và chạy Keycloak — ĐÂY LÀ ĐƯỜNG CHẠY CHÍNH.
#
#      ./deploy-keycloak.sh
#
#  Đừng gọi `docker compose up` trực tiếp cho Keycloak: Keycloak CHỈ mở cổng
#  8443 khi ./certs/cert.pem và ./certs/key.pem đã tồn tại. Thiếu chúng thì
#  container vẫn lên xanh, vẫn phục vụ HTTP, nhưng 8443 không có ai nghe —
#  và KHÔNG có dòng log nào báo điều đó. Script này sinh cert trước khi up,
#  rồi kiểm tra lại 8443 thật sự trả lời.
#
#  Chạy lại nhiều lần được: cert đã có thì giữ nguyên, container thì
#  docker compose tự điều hoà.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")"

PG_COMPOSE=docker-compose.postgres.yml
KC_COMPOSE=docker-compose.keycloak.yml

# --- 1. .env ---------------------------------------------------------------
if [ ! -f .env ]; then
    cp .env.example .env
    echo "Đã tạo .env từ .env.example."
    echo "Hãy mở .env điền mật khẩu và KEYCLOAK_HOSTNAME_URL rồi chạy lại script."
    exit 1
fi
set -a; . ./.env; set +a

: "${KEYCLOAK_PORT:=8180}"
: "${KEYCLOAK_HTTPS_PORT:=8443}"
CN="${KEYCLOAK_CERT_CN:-keycloak.local}"
SANS="${KEYCLOAK_CERT_SANS:-DNS:${CN},DNS:localhost,IP:127.0.0.1}"

# --- 2. Chứng chỉ ----------------------------------------------------------
mkdir -p ./certs
if [ -s ./certs/cert.pem ] && [ -s ./certs/key.pem ]; then
    echo "[certs] Đã có sẵn, giữ nguyên. Muốn tạo lại: rm -rf ./certs"
else
    echo "[certs] Sinh chứng chỉ tự ký  CN=$CN"
    echo "[certs] SAN: $SANS"
    openssl req -x509 -nodes -days "${KEYCLOAK_CERT_DAYS:-365}" -newkey rsa:2048 \
        -keyout ./certs/key.pem -out ./certs/cert.pem \
        -subj "/CN=$CN" -addext "subjectAltName=$SANS" 2>/dev/null
    # Container Keycloak chạy bằng uid 1000. openssl tạo key với quyền của
    # user hiện tại; uid khác 1000 thì container không đọc được và HTTPS
    # lại im lặng không bật.
    chmod 644 ./certs/cert.pem ./certs/key.pem
fi

# --- 3. Khởi động ----------------------------------------------------------
echo "[up] PostgreSQL ..."
docker compose -f "$PG_COMPOSE" up -d
echo "[up] Keycloak ..."
docker compose -f "$KC_COMPOSE" up -d

# --- 4. Chờ sẵn sàng và KIỂM TRA HTTPS THẬT ---------------------------------
echo -n "[wait] Chờ Keycloak sẵn sàng "
for i in $(seq 1 60); do
    if curl -ksS -o /dev/null "https://127.0.0.1:${KEYCLOAK_HTTPS_PORT}/realms/master" 2>/dev/null; then
        echo " OK"
        break
    fi
    echo -n "."
    sleep 5
    if [ "$i" -eq 60 ]; then
        echo
        echo "[LỖI] 8443 không trả lời sau 5 phút."
        echo "      Xem log:  docker compose -f $KC_COMPOSE logs --tail=50 keycloak"
        echo "      Kiểm tra log có dòng: Listening on: ... and https://0.0.0.0:8443"
        echo "      Không có 'https' trong dòng đó nghĩa là Keycloak không đọc được cert."
        exit 1
    fi
done

ISSUER=$(curl -ksS "https://127.0.0.1:${KEYCLOAK_HTTPS_PORT}/realms/master/.well-known/openid-configuration" \
         | sed -n 's/.*"issuer":"\([^"]*\)".*/\1/p')

echo
echo "HTTP   : http://localhost:${KEYCLOAK_PORT}"
echo "HTTPS  : https://${CN}:${KEYCLOAK_HTTPS_PORT}   (cert tự ký -> trình duyệt sẽ cảnh báo, curl dùng -k)"
echo "issuer : ${ISSUER:-<không đọc được>}"
case "$ISSUER" in
    https://*) ;;
    *) echo
       echo "[CẢNH BÁO] issuer không phải https. Sửa KEYCLOAK_HOSTNAME_URL trong .env"
       echo "           thành https://${CN}:${KEYCLOAK_HTTPS_PORT} rồi chạy lại script," 
       echo "           nếu không client OIDC sẽ bị đẩy về HTTP." ;;
esac
echo
echo "Truy cập bằng tên miền thì thêm vào /etc/hosts trên MÁY CLIENT:"
echo "    <IP-máy-chủ>  $CN"
