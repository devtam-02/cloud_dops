# Chạy promotion-ingestion bằng Docker, kèm xác thực Kafka Kerberos

Ba stack độc lập, chạy bằng ba file compose riêng, nối nhau qua **một network chung**
và **một volume keytab chung**.

```
../../infrastructure           mariadb · kafka (PLAINTEXT) · redis · minio · ES
          │                     → tạo network `promix-local`
          ▼
../../krb-experiment           KDC · krb-kafka (SASL/GSSAPI) · Kafka UI
          │                     → tạo volume `krb-share` (krb5.conf + keytab)
          ▼
services/ingestion (thư mục này)  devtam2x/ingestion:latest
```

## Thứ tự chạy — bắt buộc

```bash
# 1) Hạ tầng + network
cd ../../infrastructure && cp .env.example .env && docker compose up -d

# 2) Kerberos: KDC sinh principal + keytab ra volume dùng chung
cd ../krb-experiment && cp .env.example .env && docker compose up -d --build

# 3) Service
cd ../services/ingestion && cp .env.example .env && docker compose up -d
docker compose logs -f
```

Network và volume ở bước 3 đều khai `external`, nên Compose **không tự tạo**. Chạy sai thứ tự
sẽ lỗi ngay `network ... not found` hoặc `volume ... not found` — lỗi rõ ràng, không âm thầm.

## Keytab: không phải copy tay nữa

`kdc/entrypoint.sh` giờ tạo sẵn principal `ingestion@KAFKA.LOCAL` và xuất
`/krb/ingestion.keytab` ngay lần khởi tạo đầu tiên. Container ingestion mount volume
`kafka-kerberos_krb-share` ở `/krb` (chỉ đọc) và dùng thẳng:

```properties
ingestion.kafka.bi-data.security.principal=ingestion@KAFKA.LOCAL
ingestion.kafka.bi-data.security.key-tab=/krb/ingestion.keytab
```

Không có keytab nào nằm trong repo, trong image, hay trong gói này.

> **KDC đã chạy từ trước?** Không cần làm gì. `kdc/entrypoint.sh` kiểm tra và bổ sung
> principal/keytab còn thiếu ở **mỗi lần khởi động**, không chỉ lần khởi tạo đầu — nên
> một volume `krb-kdc-db` cũ (dựng khi chưa có principal `ingestion`) sẽ tự lành sau
> `docker compose up -d`. Keytab đã có thì không bị ghi đè, kvno giữ nguyên.

## Cấu hình

`config/application-local.properties`, nạp vào container qua
`SPRING_CONFIG_ADDITIONAL_LOCATION` (không dùng `SPRING_CONFIG_LOCATION` — cái đó sẽ vứt bỏ
config gốc đóng trong image).

Nội dung lấy nguyên từ **config staging của chính promotion-ingestion** trong repo cấu hình
(`promotion-ingestion/staging/application.properties`, commit `2d1d3c7`). Chỉ các trường kết
nối dịch vụ được đổi:

| Key | Staging | Local |
|---|---|---|
| `spring.datasource.url` | `10.254.181.137:4006/promotion_ingestion` | `mariadb:3306/promotion_ingestion` |
| `spring.datasource.username` / `.password` | user riêng + secret | `root` / `${MARIADB_ROOT_PASSWORD}` (từ `.env`) |
| `promix.messaging.kafka.bootstrap-servers` | 3 broker `10.254.181.135-137:9092` | `kafka:9092` |
| `promix.cache.redisson.mode` | `CLUSTER` | `SINGLE` |
| `promix.cache.redisson.cluster.nodes[0..2]` | 3 node `10.211.118.187-189:9379` | `address=redis://redis:6379` |
| `promix.cache.redisson.password` | secret | `${REDIS_PASSWORD}` (từ `.env`) |
| `eureka.client.enabled` | `true` | `false` (local không có service registry) |
| `*.consumer.group-id` | `ingestion-group-staging` | `ingestion-group-local` |

Mọi thứ khác — producer/consumer tuning, retry, DLQ, batch-processing, tracing, logging —
giữ nguyên như staging.

Riêng khối `ingestion.kafka.bi-data.*` là **thêm mới**: config staging không có vì PR #7 chưa
triển khai.

## Hai cụm Kafka, đừng nhầm

| | Cụm nội bộ | Cụm BI/Data |
|---|---|---|
| Địa chỉ | `kafka:9092` | `kafka.kafka.local:9094` |
| Bảo mật | PLAINTEXT | SASL_PLAINTEXT / GSSAPI |
| Thuộc stack | `infrastructure` | `krb-experiment` |
| Service dùng để | đọc topic nội bộ, **ghi output và DLQ** | chỉ **đọc** event BI/Data |

`BiDataKafkaConfig.biDataDlqRecoverer()` ghi DLQ về **cụm nội bộ**, không phải cụm Kerberos.
Thiếu cụm nội bộ thì consumer nhận được message nhưng không xuất được gì và kẹt retry vô hạn.

## Kiểm tra

```bash
# health
curl -s http://localhost:16070/actuator/health | jq .

# chỉ báo riêng cho DLQ của luồng BI/Data
curl -s http://localhost:16070/actuator/health | jq '.components.biDataDlqHealthIndicator'

# bơm thử một event (CHẠY SAU khi service đã kết nối: auto-offset-reset=latest)
docker compose -f ../../krb-experiment/docker-compose.yml --profile tools up -d kafka-client
docker compose -f ../../krb-experiment/docker-compose.yml exec kafka-client bash -c \
  'echo "{\"eventId\":\"evt-1\",\"occurredAt\":\"2026-11-08T07:00:00Z\",\"data\":{\"segmentId\":\"SEG-001\",\"sourceId\":\"SRC-001\",\"operator\":\"IN\",\"promotionDate\":\"2026-11-08\"}}" \
   | kafka-console-producer --bootstrap-server kafka.kafka.local:9094 \
       --producer.config /krb/client.properties --topic promotion_platform_bi_events'
```

Log phải có `=== BI/Data Kafka Consumer Configuration ===` lúc khởi động, rồi
`[BI_DATA] Received 1 messages`.

## Cổng

| Dịch vụ | Host |
|---|---|
| ingestion | **16070** → 8080 trong container |
| Kafka UI (Kerberos) | 8080 |
| Kafka UI promotion (kafbat) | 8989 |
| Kafka Kerberos | 9094 · KDC 88, 749 |
| Kafka nội bộ | 9092, 19092 |
| MariaDB 3306 · Redis 6379 · MinIO 9000/9001 · ES 9200 · mongo-express 8101 |

Ingestion dùng 16070 vì 8080 đã bị Kafka UI của stack Kerberos chiếm.

## Chưa kiểm chứng

Ba điểm sau phụ thuộc vào image `devtam2x/ingestion:latest` mà tôi chưa chạy thử:

1. **Healthcheck dùng `wget`** — theo mẫu compose gốc của bạn. Image không có `wget`
   thì container sẽ luôn `unhealthy` dù app chạy tốt; đổi sang `curl` hoặc bỏ healthcheck.
2. **Đường dẫn `/config`** — image chạy bằng user không phải root thì cần quyền đọc; đã mount `:ro`.
3. **Liquibase** tự chạy khi khởi động và tạo schema trong database rỗng. Lần đầu sẽ lâu.
