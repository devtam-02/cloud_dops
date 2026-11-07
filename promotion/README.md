# promotion — môi trường local

Ba stack độc lập, mỗi stack một thư mục và một file `docker-compose.yml` riêng,
nối với nhau qua **một network chung** và **một volume keytab chung**.

```
promotion/
├── infrastructure/     mariadb · redis · kafka (PLAINTEXT) · kafbat · mongodb · minio · elasticsearch
│                       → tạo network `promix-local`
├── krb-experiment/     KDC (Kerberos) · krb-kafka (SASL/GSSAPI) · Kafka UI
│                       → tạo volume `krb-share` (krb5.conf + keytab)
└── services/
    └── ingestion/      devtam2x/ingestion:latest
```

## Thứ tự chạy — bắt buộc

```bash
cd infrastructure   && cp .env.example .env && docker compose up -d
cd ../krb-experiment && cp .env.example .env && docker compose up -d --build
cd ../services/ingestion && cp .env.example .env && docker compose up -d
```

Network `promix-local` và volume `krb-share` đều khai `external` ở hai stack sau, nên Compose
**không tự tạo**. Sai thứ tự sẽ lỗi rõ ràng `network promix-local not found`, không âm thầm.

Tên network và volume được đặt **tường minh** (`name:`) thay vì để Compose tự thêm tiền tố tên
project. Nhờ vậy đổi tên thư mục hay tên project không làm gãy tham chiếu giữa ba stack.

## Bí mật

Mỗi thư mục có `.env.example`; copy thành `.env` rồi điền. `.env` đã nằm trong `.gitignore`.

Mật khẩu trong `services/ingestion/.env` phải **trùng** với `infrastructure/.env`
(`MARIADB_ROOT_PASSWORD`, `REDIS_PASSWORD`) — service đọc chúng qua biến môi trường, file
`.properties` chỉ chứa `${...}` chứ không chứa giá trị thật.

Các biến bí mật dùng cú pháp `${VAR:?...}`: thiếu là compose dừng ngay với thông báo rõ ràng,
thay vì lặng lẽ dùng mật khẩu mặc định.

## Hai cụm Kafka — đừng nhầm

| | Cụm nội bộ | Cụm BI/Data |
|---|---|---|
| Địa chỉ trong network | `kafka:9092` | `kafka.kafka.local:9094` |
| Bảo mật | PLAINTEXT | SASL_PLAINTEXT / GSSAPI |
| Thuộc stack | `infrastructure` | `krb-experiment` |
| ingestion dùng để | đọc topic nội bộ, **ghi output và DLQ** | chỉ **đọc** event BI/Data |

Service Kerberos tên là `krb-kafka`, **không** phải `kafka`: hai container cùng alias `kafka`
trên một network sẽ khiến Docker trả về luân phiên, app lúc trúng broker này lúc trúng broker kia.
Alias `kafka.kafka.local` giữ nguyên vì đó là hostname trong Service Principal Kerberos.

## Đặt tên container

`infrastructure` **không** khai `container_name` — Docker tự sinh `promotion-infra-<service>-1`.
Tên cố định sẽ chặn việc chạy song song hai stack trên cùng một máy và xung đột với container
cũ còn sót của project khác.

`krb-experiment` thì khai tên tường minh với tiền tố **`krb_`** (`krb_kdc`, `krb_kafka`,
`krb_kafka_ui`, `krb_kafka_client`) để nhìn là biết ngay broker nào là Kerberos:

| | Kafka nội bộ | Kafka Kerberos |
|---|---|---|
| Container | `promotion-infra-kafka-1` | `krb_kafka` |
| Service / alias DNS | `kafka` | `krb-kafka`, `kafka.kafka.local` |
| Cổng | 9092, 19092 | 9094 |

## Cổng

| Dịch vụ | Host |
|---|---|
| ingestion | 16070 |
| Kafka UI (Kerberos) | 8080 |
| kafbat (Kafka nội bộ) | 8989 |
| Kafka Kerberos | 9094 |
| KDC | 88/tcp, 88/udp, 749/tcp |
| Kafka nội bộ | 9092, 19092 |
| MariaDB 3306 · Redis 6379 · MongoDB 27017 · MinIO 9000/9001 · Elasticsearch 9200 |

Tất cả đổi được qua `.env`.

## Tài liệu chi tiết

- `krb-experiment/HUONG-DAN.md` — dựng Kerberos, quản trị principal, ACL, lỗi thường gặp
- `krb-experiment/KET-NOI-SERVICE.md` — nối service vào cụm Kerberos (chạy ngoài Docker)
- `services/ingestion/README.md` — chạy ingestion bằng Docker, bảng ánh xạ config staging → local
