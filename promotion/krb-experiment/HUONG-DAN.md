# Kafka + Kerberos (SASL/GSSAPI) + Kafka UI — Hướng dẫn triển khai

Stack một lệnh `docker compose up -d`, gồm:

| Thành phần | Image | Port publish | Ghi chú |
|---|---|---|---|
| **KDC** (MIT Kerberos) | build từ `./kdc` (ubuntu 22.04) | `88/udp`, `88/tcp`, `749/tcp` | tự tạo realm, principal, keytab |
| **Kafka broker** (KRaft, không ZooKeeper) | `confluentinc/cp-kafka:7.7.1` | `9094/tcp` | listener client **bắt buộc** SASL_PLAINTEXT / GSSAPI |
| **Kafka UI** | `provectuslabs/kafka-ui:v0.7.2` | `8080/tcp` | tự đăng nhập Kerberos bằng keytab |
| **kafka-client** (tuỳ chọn) | `confluentinc/cp-kafka:7.7.1` | — | container CLI để test, bật bằng profile `tools` |

Tất cả đều bind `0.0.0.0` → **truy cập được từ máy khác trong mạng**, không chỉ localhost.

---

## 1. Kiến trúc & quyết định thiết kế

```
         máy khác trong LAN
      ┌──────────────────────┐
      │ kinit → lấy TGT      │──── 88/udp,tcp ────►┌─────────┐
      │ kafka-console-*      │                     │   KDC   │
      └───────┬──────────────┘◄─── service ticket ─└─────────┘
              │ SASL_PLAINTEXT / GSSAPI
              ▼ 9094/tcp
      ┌──────────────────┐        ┌──────────────┐
      │  Kafka broker    │◄───────│   Kafka UI   │ :8080
      │  KRaft (1 node)  │ GSSAPI └──────────────┘
      └──────────────────┘
```

* **Chỉ một listener cho client** (`BROKER://0.0.0.0:9094`) và nó luôn là `SASL_PLAINTEXT/GSSAPI`.
  Không có cửa hậu PLAINTEXT nào ra ngoài. Listener `CONTROLLER:9093` của KRaft chỉ sống trong
  container, không publish, nên để PLAINTEXT cho đơn giản.
* **Hostname chứ không phải IP.** Kerberos định danh dịch vụ bằng Service Principal
  `kafka/<hostname>@REALM`, trong đó `<hostname>` chính là host trong `advertised.listeners`.
  Vì vậy broker được quảng bá là `kafka.kafka.local`, không phải IP. Client ở máy khác chỉ cần
  thêm một dòng vào `/etc/hosts` (xem §4). Nếu dùng IP, Java GSSAPI sẽ không tìm ra SPN và báo
  `Server not found in Kerberos database`.
* **Advertised port = container port = host port = 9094.** Nhờ vậy cùng một địa chỉ
  `kafka.kafka.local:9094` dùng được cả trong docker network lẫn từ bên ngoài.
* Keytab + `krb5.conf` do KDC sinh ra và đẩy vào volume dùng chung `krb-share`; Kafka và Kafka UI
  mount volume đó ở chế độ chỉ đọc. Không có keytab nào bị commit vào repo.

### Principal được tạo sẵn

| Principal | Loại | Dùng cho |
|---|---|---|
| `kafka/kafka.kafka.local@KAFKA.LOCAL` | keytab `kafka.keytab` | service principal của broker |
| `kafkaui@KAFKA.LOCAL` | keytab `kafkaui.keytab` | Kafka UI |
| `kafkaclient@KAFKA.LOCAL` | keytab `kafkaclient.keytab` | ứng dụng / service chạy nền |
| `alice@KAFKA.LOCAL`, `bob@KAFKA.LOCAL` | mật khẩu (`CLIENT_PASSWORD`) | người dùng `kinit` thủ công |
| `admin/admin@KAFKA.LOCAL` | mật khẩu (`KDC_ADMIN_PASSWORD`) | quản trị KDC qua `kadmin` |

---

## 2. Cấu trúc thư mục

```
.
├── docker-compose.yml
├── .env                        # realm, hostname, port, mật khẩu — sửa ở đây
├── HUONG-DAN.md
├── kdc/
│   ├── Dockerfile
│   └── entrypoint.sh           # tạo realm + principal + keytab, chạy krb5kdc & kadmind
├── kafka/
│   └── wait-for-krb.sh         # chờ KDC phát keytab rồi mới start broker
└── client/
    ├── krb5.conf               # copy sang /etc/krb5.conf ở máy client
    ├── client.properties       # client đã kinit (ticket cache)
    └── client-keytab.properties# client dùng keytab, không cần kinit
```

---

## 3. Chạy trên máy chủ

```bash
# 1) Sửa .env nếu cần (ít nhất là đổi 3 mật khẩu trước khi dùng thật)
vi .env

# 2) Khởi động
docker compose up -d --build

# 3) Theo dõi
docker compose ps
docker compose logs -f kafka
```

Lần đầu KDC sẽ tự khởi tạo database và in ra danh sách principal vừa tạo. Broker chờ keytab
xuất hiện rồi mới start, nên thứ tự luôn đúng kể cả khi `docker compose up` chạy song song.

Mở UI: **http://\<IP-máy-chủ\>:8080** — cluster `kerberos-cluster` phải ở trạng thái *online*.

Container CLI để test (tuỳ chọn):

```bash
docker compose --profile tools up -d kafka-client
docker exec -it kafka-client bash
```

### Kiểm tra nhanh ngay trên máy chủ

```bash
docker exec kafka-client kafka-topics \
  --bootstrap-server kafka.kafka.local:9094 \
  --command-config /krb/client.properties \
  --create --topic demo --partitions 3 --replication-factor 1

docker exec kafka-client bash -c 'echo "hello-kerberos" | kafka-console-producer \
  --bootstrap-server kafka.kafka.local:9094 \
  --producer.config /krb/client.properties --topic demo'

docker exec kafka-client kafka-console-consumer \
  --bootstrap-server kafka.kafka.local:9094 \
  --consumer.config /krb/client.properties \
  --topic demo --from-beginning --max-messages 1
```

Chứng minh auth thực sự bị ép buộc — lệnh dưới đây (không có cấu hình Kerberos) sẽ treo rồi
timeout chứ không trả về danh sách topic:

```bash
docker exec kafka-client kafka-topics --bootstrap-server kafka.kafka.local:9094 --list
```

---

## 4. Kết nối từ máy khác

Giả sử máy chủ có IP `172.46.3.38` (thay bằng IP thật của bạn: `ip -4 addr`).

### Bước 1 — Phân giải tên

Trên **mỗi máy client**, thêm vào `/etc/hosts`
(Windows: `C:\Windows\System32\drivers\etc\hosts`):

```
172.46.3.38   kafka.kafka.local kdc.kafka.local
```

> Nếu có DNS nội bộ thì tạo 2 bản ghi A trỏ về IP máy chủ, khỏi sửa hosts từng máy.

### Bước 2 — Cài Kerberos client và đặt `krb5.conf`

```bash
# Debian/Ubuntu
sudo apt-get install -y krb5-user
# RHEL/CentOS/Rocky
sudo yum install -y krb5-workstation

sudo cp client/krb5.conf /etc/krb5.conf
```

### Bước 3 — Mở firewall trên máy chủ

```bash
sudo ufw allow 88/udp && sudo ufw allow 88/tcp   # Kerberos
sudo ufw allow 749/tcp                            # kadmin (chỉ mở nếu cần quản trị từ xa)
sudo ufw allow 9094/tcp                           # Kafka
sudo ufw allow 8080/tcp                           # Kafka UI
# firewalld: firewall-cmd --permanent --add-port=88/udp ... rồi firewall-cmd --reload
```

### Bước 4 — Lấy vé và dùng Kafka

**Cách A — đăng nhập bằng mật khẩu (người dùng thật):**

```bash
kinit alice@KAFKA.LOCAL        # mật khẩu = CLIENT_PASSWORD trong .env
klist                          # phải thấy krbtgt/KAFKA.LOCAL@KAFKA.LOCAL

kafka-topics --bootstrap-server kafka.kafka.local:9094 \
             --command-config client/client.properties --list
```

**Cách B — dùng keytab (ứng dụng chạy nền, không nhập mật khẩu):**

```bash
# lấy keytab từ máy chủ, truyền qua kênh an toàn (scp), chmod 600
docker cp krb5-kdc:/krb/kafkaclient.keytab ./kafkaclient.keytab

# sửa đường dẫn keyTab trong client/client-keytab.properties cho khớp, rồi:
kafka-topics --bootstrap-server kafka.kafka.local:9094 \
             --command-config client/client-keytab.properties --list
```

### Cấu hình cho ứng dụng Java / Spring Boot

```properties
spring.kafka.bootstrap-servers=kafka.kafka.local:9094
spring.kafka.properties.security.protocol=SASL_PLAINTEXT
spring.kafka.properties.sasl.mechanism=GSSAPI
spring.kafka.properties.sasl.kerberos.service.name=kafka
spring.kafka.properties.sasl.jaas.config=com.sun.security.auth.module.Krb5LoginModule required \
  useKeyTab=true storeKey=true \
  keyTab="/etc/kafka/kafkaclient.keytab" \
  principal="kafkaclient@KAFKA.LOCAL";
```

Thêm JVM option: `-Djava.security.krb5.conf=/etc/krb5.conf`

### Cấu hình cho Python (`confluent-kafka`)

```python
from confluent_kafka import Producer
p = Producer({
    "bootstrap.servers": "kafka.kafka.local:9094",
    "security.protocol": "SASL_PLAINTEXT",
    "sasl.mechanisms": "GSSAPI",
    "sasl.kerberos.service.name": "kafka",
    "sasl.kerberos.keytab": "/etc/kafka/kafkaclient.keytab",
    "sasl.kerberos.principal": "kafkaclient@KAFKA.LOCAL",
})
```

---

## 5. Quản trị người dùng Kerberos

Trên máy chủ:

```bash
docker exec -it krb5-kdc kadmin.local
```

```
addprinc -pw MatKhau123 charlie@KAFKA.LOCAL        # thêm user dùng mật khẩu
addprinc -randkey svc-billing@KAFKA.LOCAL          # thêm service principal
ktadd -k /krb/svc-billing.keytab svc-billing@KAFKA.LOCAL
listprincs                                          # xem danh sách
delprinc charlie@KAFKA.LOCAL
quit
```

Từ máy khác (qua port 749, dùng `admin/admin@KAFKA.LOCAL`):

```bash
kadmin -p admin/admin@KAFKA.LOCAL
```

---

## 6. Phân quyền (ACL)

Mặc định `KAFKA_ALLOW_EVERYONE_IF_NO_ACL_FOUND=true`: **đã xác thực Kerberos là dùng được mọi
topic chưa có ACL**. Đây là chế độ dễ khởi động. Để siết chặt:

1. Đổi trong `docker-compose.yml`: `KAFKA_ALLOW_EVERYONE_IF_NO_ACL_FOUND: "false"`
2. `docker compose up -d kafka`
3. Cấp quyền tường minh (tên principal đã bỏ realm, `alice@KAFKA.LOCAL` → `User:alice`):

```bash
docker exec kafka-client kafka-acls \
  --bootstrap-server kafka.kafka.local:9094 \
  --command-config /krb/client.properties \
  --add --allow-principal User:alice \
  --operation Read --operation Write --operation Describe \
  --topic demo

docker exec kafka-client kafka-acls \
  --bootstrap-server kafka.kafka.local:9094 \
  --command-config /krb/client.properties \
  --add --allow-principal User:alice --operation Read --group '*'
```

`KAFKA_SUPER_USERS` đã có `User:ANONYMOUS` — cần thiết vì listener CONTROLLER nội bộ chạy
PLAINTEXT; bỏ dòng đó ra thì broker tự chặn chính nó khi bật authorizer.

---

## 7. Vận hành

```bash
docker compose logs -f kdc kafka kafka-ui   # xem log
docker compose restart kafka                # restart broker
docker compose down                         # dừng, GIỮ dữ liệu + realm
docker compose down -v                      # XOÁ SẠCH: cả KDC database lẫn dữ liệu Kafka
```

Dữ liệu nằm ở 3 volume: `kafka-kerberos_kdc-db`, `kafka-kerberos_krb-share`,
`kafka-kerberos_kafka-data`.

> Đổi `KRB5_REALM` hoặc `KAFKA_HOST` trong `.env` **sau khi** đã chạy thì phải
> `docker compose down -v` rồi dựng lại, vì principal cũ đã nằm trong database KDC.

---

## 8. Lỗi thường gặp

| Triệu chứng | Nguyên nhân & cách xử lý |
|---|---|
| `Server not found in Kerberos database` | Client đang nối bằng **IP** thay vì `kafka.kafka.local`, hoặc thiếu dòng `/etc/hosts`. SPN phải khớp hostname trong `advertised.listeners`. |
| `Cannot locate default realm` / `KDC has no support for encryption type` | Client chưa copy `client/krb5.conf` vào `/etc/krb5.conf`, hoặc Java thiếu `-Djava.security.krb5.conf`. |
| `Clock skew too great` | Lệch giờ giữa client và KDC quá 5 phút. Bật NTP: `sudo timedatectl set-ntp true`. |
| `kinit: Invalid UID in persistent keyring name` | `krb5.conf` của client thiếu `default_ccache_name = FILE:/tmp/krb5cc_%{uid}` — file trong `client/` đã có sẵn dòng này. |
| Client treo rồi timeout, không báo lỗi rõ | Thiếu cấu hình SASL ở phía client. Broker chủ động không trả lời client không xác thực. |
| Kafka UI báo cluster *offline* | Xem `docker compose logs kafka-ui`; thường do keytab chưa được phát hoặc sai realm trong `KAFKA_CLUSTERS_0_PROPERTIES_SASL_JAAS_CONFIG`. |
| Broker không start, log dừng ở `waiting for Kerberos keytabs` | KDC lỗi. Xem `docker compose logs kdc`. (Dòng `preauth spake failed to initialize` là cảnh báo vô hại, bỏ qua.) |

---

## 9. Lưu ý bảo mật trước khi dùng thật

1. **Đổi toàn bộ mật khẩu trong `.env`** (`KDC_MASTER_PASSWORD`, `KDC_ADMIN_PASSWORD`,
   `CLIENT_PASSWORD`) và không commit `.env` lên git.
2. `SASL_PLAINTEXT` **xác thực** nhưng **không mã hoá** dữ liệu trên đường truyền. Với mạng không
   tin cậy, chuyển sang `SASL_SSL`: tạo keystore/truststore, đổi
   `KAFKA_LISTENER_SECURITY_PROTOCOL_MAP` thành `BROKER:SASL_SSL,...` và thêm các biến
   `KAFKA_SSL_KEYSTORE_*` / `KAFKA_SSL_TRUSTSTORE_*`.
3. Chỉ mở port `749` (kadmin) khi thật sự cần quản trị từ xa.
4. Keytab tương đương mật khẩu — truyền bằng `scp`, đặt `chmod 600`, không đưa vào image hay git.
5. Bật ACL (§6) và bỏ bớt principal trong `KAFKA_SUPER_USERS` khi lên môi trường thật.
