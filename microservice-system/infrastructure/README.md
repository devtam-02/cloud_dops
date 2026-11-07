# microservice-system / infrastructure

Hai stack tách riêng thành hai file compose, nối nhau qua network `microservice-local`.

| File | Service | Cổng host |
|---|---|---|
| `docker-compose.postgres.yml` | PostgreSQL 16.6 | 5432 |
| `docker-compose.keycloak.yml` | Keycloak 26.0.7 (DB = PostgreSQL) | 8180 |

Cả hai bind `0.0.0.0` nên gọi được từ máy khác trong mạng, không chỉ localhost.

## Chạy

```bash
cp .env.example .env     # rồi điền mật khẩu và KEYCLOAK_HOSTNAME_URL
docker compose -f docker-compose.postgres.yml up -d
docker compose -f docker-compose.keycloak.yml  up -d
```

**Thứ tự bắt buộc.** File postgres tạo network `microservice-local`; file keycloak khai
network đó là `external` nên không tự tạo. Chạy sai thứ tự sẽ lỗi rõ ràng
`network microservice-local not found`.

Admin console: `http://<IP-máy-chủ>:8180`

## Database cho Keycloak

`initdb/01-keycloak-db.sh` tạo database `keycloak` và user `keycloak` riêng, **không** dùng
superuser `postgres`. Keycloak tự chạy migration schema nên chỉ cần toàn quyền trên database
của chính nó.

Script chạy đúng **một lần**, lúc volume `postgres-data` còn rỗng — đó là cơ chế của image
postgres. Đổi `KEYCLOAK_DB_*` trong `.env` sau khi đã chạy thì script **không** chạy lại; muốn
làm lại phải `docker compose -f docker-compose.postgres.yml down -v` (xoá sạch dữ liệu).

Có một dòng dễ bị bỏ sót trong script:

```sql
GRANT ALL ON SCHEMA public TO "keycloak";
ALTER SCHEMA public OWNER TO "keycloak";
```

Từ PostgreSQL 15, user thường không còn mặc định được quyền tạo bảng trong schema `public`.
Thiếu hai dòng này, Keycloak khởi động sẽ chết giữa lúc chạy migration.

## `KEYCLOAK_HOSTNAME_URL` — đừng để trống nếu có client ở máy khác

Giá trị này thành `KC_HOSTNAME`, và Keycloak nhúng nó vào:

- link trong admin console,
- **`issuer` của token**,
- redirect URI của luồng OIDC.

Để trống thì Keycloak suy ra từ header của từng request: chạy vẫn được, nhưng token cấp cho
client gõ `localhost` sẽ có issuer khác token cấp cho client gõ IP — service nào xác thực token
theo issuer sẽ từ chối một trong hai. Đặt đúng IP hoặc tên miền thật:

```
KEYCLOAK_HOSTNAME_URL=http://192.168.102.254:8180
```

## Bẫy: `HTTPS required`

Realm `master` mặc định có `sslRequired=EXTERNAL`. Keycloak cho phép HTTP khi client đến từ
**dải IP riêng** (`10.x`, `172.16–31.x`, `192.168.x`, loopback) và **từ chối** khi đến từ địa
chỉ ngoài dải đó:

```json
{"error":"invalid_request","error_description":"HTTPS required"}
```

Đã kiểm chứng cả hai chiều trên cùng một máy: gọi qua một IP **ngoài** dải riêng thì bị từ
chối; gọi qua IP `10.x` thì discovery trả đúng issuer và lấy được token.

Mạng LAN thông thường (`192.168.x` / `10.x`) nên không vướng. Nếu vướng, hai cách:

```bash
# Cách đúng: đặt sau reverse proxy có TLS, rồi bỏ --http-enabled
#            và đổi KEYCLOAK_HOSTNAME_URL sang https://...

# Cách tạm, CHỈ cho môi trường thử nghiệm nội bộ:
docker compose -f docker-compose.keycloak.yml exec keycloak \
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 --realm master \
    --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"
docker compose -f docker-compose.keycloak.yml exec keycloak \
  /opt/keycloak/bin/kcadm.sh update realms/master -s sslRequired=NONE
```

## Kiểm tra

```bash
# Keycloak sẵn sàng (health nằm ở cổng quản trị 9000, không phải 8080)
docker compose -f docker-compose.keycloak.yml exec keycloak \
  bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000; echo -e "GET /health/ready HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" >&3; cat <&3'

# OIDC discovery — issuer phải khớp KEYCLOAK_HOSTNAME_URL
curl -s http://<IP>:8180/realms/master/.well-known/openid-configuration | jq .issuer

# Lấy token admin
curl -s -X POST http://<IP>:8180/realms/master/protocol/openid-connect/token \
  -d client_id=admin-cli -d username=admin -d password='<mật khẩu>' \
  -d grant_type=password | jq -r .access_token

# Dữ liệu thật nằm trong postgres
docker compose -f docker-compose.postgres.yml exec postgres \
  psql -U keycloak -d keycloak -c "\dt" | head
```

## Vài lựa chọn kỹ thuật

**`start` chứ không `start-dev`.** `start-dev` dùng database H2 trong bộ nhớ và bật nhiều mặc
định chỉ hợp cho dev; `start` mới thực sự ghi vào PostgreSQL. Đổi lại phải khai báo tường minh
`--http-enabled` và `--hostname-strict=false`.

**Healthcheck dùng `/dev/tcp` của bash.** Image Keycloak không có `curl` lẫn `wget`, và từ phiên
bản 25 endpoint health chuyển sang cổng quản trị 9000 — healthcheck gọi `localhost:8080/health`
sẽ luôn fail dù Keycloak chạy tốt.

**`KC_BOOTSTRAP_ADMIN_USERNAME`** là tên biến của Keycloak 26. Bản ≤ 25 dùng `KEYCLOAK_ADMIN` /
`KEYCLOAK_ADMIN_PASSWORD`; đặt tên cũ cho bản 26 thì tài khoản admin không được tạo và bạn sẽ
không đăng nhập được, không có lỗi rõ ràng. Tài khoản này chỉ được tạo ở lần khởi động đầu tiên.

## Trước khi dùng thật

1. Đổi toàn bộ mật khẩu trong `.env`; không commit `.env`.
2. Dựng TLS (reverse proxy) rồi bỏ `--http-enabled=true`, đổi `KEYCLOAK_HOSTNAME_URL` sang
   `https://...`. HTTP ở đây chỉ hợp cho mạng nội bộ tin cậy.
3. Đổi `POSTGRES_BIND` thành `127.0.0.1` nếu không cần truy cập Postgres từ máy khác — mở
   5432 ra LAN là bề mặt tấn công không cần thiết.
4. Tài khoản admin tạm nên được thay bằng tài khoản thật rồi xoá đi.
