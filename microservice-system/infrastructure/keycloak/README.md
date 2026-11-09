# microservice-system / infrastructure / keycloak

Hai stack tách riêng thành hai file compose, nối nhau qua network `microservice-local`.
Network này do file postgres tạo và được `../elk` dùng lại.

| File | Service | Cổng host |
|---|---|---|
| `docker-compose.postgres.yml` | PostgreSQL 16.6 | 5432 |
| `docker-compose.keycloak.yml` | Keycloak 26.0.7 (DB = PostgreSQL) | 8180 |

Cả hai bind `0.0.0.0` nên gọi được từ máy khác trong mạng, không chỉ localhost.

## Chạy

```bash
./deploy-keycloak.sh
```

**Đây là đường chạy chính**, dùng cho cả lần khởi tạo đầu lẫn các lần chạy sau. Script làm
tuần tự: tạo `.env` từ `.env.example` nếu chưa có (rồi dừng để bạn điền) → sinh chứng chỉ
tự ký vào `./certs` → up PostgreSQL → up Keycloak → **chờ và kiểm tra 8443 thật sự trả lời**,
in ra `issuer` và cảnh báo nếu nó không phải `https`.

Chạy lại nhiều lần được: cert đã có thì giữ nguyên.

> **Đừng gọi `docker compose up` trực tiếp cho Keycloak.** Keycloak chỉ mở 8443 khi
> `./certs/cert.pem` và `./certs/key.pem` đã tồn tại. Bỏ qua bước sinh cert thì container vẫn
> lên xanh, vẫn phục vụ HTTP, nhưng 8443 không có ai nghe — và không có dòng log nào báo điều
> đó. Đó chính là kiểu hỏng khó lần ra nhất ở đây.

Chỉ dùng compose trực tiếp khi cần thao tác lẻ (xem log, restart một service):

```bash
docker compose -f docker-compose.keycloak.yml logs -f keycloak
docker compose -f docker-compose.keycloak.yml restart keycloak
docker compose -f docker-compose.postgres.yml down        # giữ dữ liệu
```

**Thứ tự bắt buộc** nếu tự chạy tay: file postgres tạo network `microservice-local`; file
keycloak khai network đó là `external` nên không tự tạo. Sai thứ tự sẽ lỗi rõ ràng
`network microservice-local not found`. Script đã lo đúng thứ tự này.

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

## HTTPS ở cổng 8443

```bash
./deploy-keycloak.sh      # sinh cert tự ký vào ./certs rồi up cả hai stack
```

Keycloak **chỉ mở 8443 khi `./certs/cert.pem` và `./certs/key.pem` tồn tại**. Thiếu chúng thì
container vẫn lên xanh và vẫn phục vụ HTTP 8180 — không có lỗi nào báo rằng HTTPS đã bị bỏ qua.
Đây là lý do phổ biến nhất khiến "8443 không chạy".

Ba thứ phải đúng cùng lúc:

| | Sai | Đúng |
|---|---|---|
| Cert | `./certs` chưa tồn tại → bind mount tạo thư mục rỗng | chạy `./deploy-keycloak.sh` trước |
| Biến proxy | `KC_PROXY: edge` | `--proxy-headers=xforwarded` trong `command` |
| Hostname | `KEYCLOAK_HOSTNAME_URL=http://...:8180` | `https://keycloak.local:8443` |

`KC_PROXY` bị bỏ từ bản 24 và **xoá hẳn ở bản 26**, lại mang nghĩa "TLS kết thúc ở proxy" — tức
bảo Keycloak đừng tự phục vụ TLS. Để nguyên thì 8443 không bao giờ mở.

`KEYCLOAK_HOSTNAME_URL` ghi `http://...:8180` thì dù 8443 đã mở, `issuer` và mọi link trong
admin console vẫn là HTTP, và client OIDC bị chuyển về HTTP.

### SAN của chứng chỉ

`KEYCLOAK_CERT_SANS` phải liệt kê **mọi địa chỉ client sẽ gõ**. Thiếu SAN khớp thì trình duyệt
và client OIDC báo lỗi sai tên miền ngay cả khi đã chấp nhận chứng chỉ tự ký:

```
KEYCLOAK_CERT_SANS=DNS:keycloak.local,DNS:localhost,IP:127.0.0.1,IP:192.168.102.254
```

Truy cập bằng tên miền thì thêm vào `/etc/hosts` trên **máy client**:

```
<IP-máy-chủ>  keycloak.local
```

### Đã kiểm chứng

```
Listening on: http://0.0.0.0:8080 and https://0.0.0.0:8443
issuer: https://keycloak.local:8443/realms/master
curl -k https://...:8443/realms/master           -> 200, TLSv1.3
curl -k POST .../protocol/openid-connect/token   -> access_token OK
SAN: DNS:keycloak.local, DNS:localhost, IP:127.0.0.1, IP:<ip-máy-chủ>
```

### Healthcheck không dùng cổng 9000

Khi HTTPS bật, Keycloak chuyển **cả interface quản trị 9000 sang HTTPS**. Image Keycloak không
có `curl`, `wget` lẫn `openssl` — chỉ có `bash` — nên không cách nào bắt tay TLS từ trong
container. Healthcheck cũ gọi `9000/health/ready` sẽ kẹt mãi ở `health: starting` dù Keycloak
chạy hoàn toàn bình thường.

Thay bằng request HTTP tới listener 8080 hỏi OIDC discovery của realm master: chỉ trả về
`issuer` khi realm đã nạp xong, nên là tín hiệu sẵn sàng thật chứ không chỉ "cổng đã mở".

### Chứng chỉ tự ký không dành cho môi trường thật

`./certs` nằm trong `.gitignore` (cả `*.pem`, `*.key`) — private key không bao giờ được commit,
nhất là khi repo này đang public. Môi trường thật phải dùng cert do CA cấp, hoặc đặt Keycloak
sau reverse proxy có TLS rồi bỏ `--http-enabled=true`.

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
