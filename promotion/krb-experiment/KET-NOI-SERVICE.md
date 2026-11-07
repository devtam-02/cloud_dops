# Kết nối `promotion-ingestion` (PR #7) vào stack Kafka + Kerberos local

Hướng dẫn này nối **PR #7 — "Add Kerberos-authenticated Kafka consumer for BI/Data cluster"**
(`PROMOTION/promotion-ingestion`, `feature/bi-data-kafka-consumer` → `release`) vào stack Kerberos
bạn vừa dựng, để test end-to-end **trước khi** đội BI/Data cấp hạ tầng thật.

> Stack local đóng vai **cụm BI/Data**. Nó **không** thay thế cụm nội bộ của promix-messaging —
> đọc kỹ mục 6.1, đây là hiểu nhầm dễ mắc nhất.

---

## 1. PR #7 làm gì

Thêm một consumer thứ hai, trỏ sang **một cụm Kafka độc lập** dùng Kerberos:

| File | Vai trò |
|---|---|
| `BiDataKafkaProperties` | bind prefix `ingestion.kafka.bi-data` |
| `BiDataKafkaConfig` | dựng `ConsumerFactory` + container factory riêng, ráp `sasl.jaas.config` GSSAPI |
| `BiDataEventConsumer` | `@KafkaListener` batch, đẩy vào `ProcessExternalEventUsecase` (dùng chung pipeline với consumer cũ) |
| `018-update-bi-events-source-topic-pattern.xml` | Liquibase, cập nhật `EventSchema` |

Toàn bộ nằm sau `@ConditionalOnProperty(... bi-data.enabled=true)` → mặc định tắt, bật mới chạy.

Phần `## Next steps` của PR liệt kê những thứ còn thiếu. Stack local trả lời được gần hết:

| PR cần | Stack local cấp | Trạng thái |
|---|---|---|
| nội dung `krb5.conf` (realm, KDC host) | realm `KAFKA.LOCAL`, KDC `kdc.kafka.local` | ✅ `client/krb5.conf` |
| principal + keytab cho service | tạo ở mục 2 | ✅ |
| SASL service name có đúng `kafka` không | `sasl.kerberos.service.name=kafka` | ✅ khớp mặc định |
| `SASL_PLAINTEXT` hay `SASL_SSL` | stack dùng `SASL_PLAINTEXT` | ✅ khớp mặc định |
| tên topic thật | tạo đúng `promotion_platform_bi_events` | ✅ |
| quy ước `data.operator` IN/OUT | tự bạn bơm event mẫu | ✅ mục 5 |
| egress tới KDC port 88 (và 464) | cổng 88 đã publish | ✅ |

Nói cách khác: **mọi câu hỏi PR đang chờ BI/Data trả lời đều có thể test giả lập tại đây.**

---

## 2. Tạo principal và keytab riêng cho service

Đừng dùng lại `kafkaclient` — mỗi service một danh tính riêng để còn truy vết và thu hồi độc lập.

```bash
cd /đường/dẫn/kafka
docker compose up -d                       # bật stack nếu đang tắt

docker exec krb5-kdc kadmin.local -q "addprinc -randkey ingestion@KAFKA.LOCAL"
docker exec krb5-kdc kadmin.local -q "ktadd -k /krb/ingestion.keytab ingestion@KAFKA.LOCAL"
docker exec krb5-kdc chmod 644 /krb/ingestion.keytab

# lấy keytab ra host để mount vào service
docker cp krb5-kdc:/krb/ingestion.keytab ./ingestion.keytab
chmod 600 ./ingestion.keytab
```

`-randkey` = sinh khóa ngẫu nhiên, không có mật khẩu — đúng kiểu dùng cho service.

---

## 3. Tạo topic

`concurrency=3` trong PR, nên topic cần **ít nhất 3 partition**, không thì 2 trong 3 consumer thread
ngồi không.

```bash
docker compose --profile tools up -d kafka-client

docker exec kafka-client kafka-topics \
  --bootstrap-server kafka.kafka.local:9094 \
  --command-config /krb/client.properties \
  --create --topic promotion_platform_bi_events \
  --partitions 3 --replication-factor 1
```

---

## 4. Cấu hình `promotion-ingestion`

Điền vào `app-config` của môi trường dev (hoặc `application-local.properties` khi chạy tay). Các
giá trị dưới đây đã được kiểm chứng chạy được với stack này:

```properties
ingestion.kafka.bi-data.enabled=true
ingestion.kafka.bi-data.bootstrap-servers[0]=kafka.kafka.local:9094
ingestion.kafka.bi-data.topic=promotion_platform_bi_events
ingestion.kafka.bi-data.group-id=ingestion-bi-data-group
ingestion.kafka.bi-data.concurrency=3
ingestion.kafka.bi-data.max-poll-records=50
ingestion.kafka.bi-data.security.protocol=SASL_PLAINTEXT
ingestion.kafka.bi-data.security.mechanism=GSSAPI
ingestion.kafka.bi-data.security.service-name=kafka
ingestion.kafka.bi-data.security.principal=ingestion@KAFKA.LOCAL
ingestion.kafka.bi-data.security.key-tab=/etc/kafka/ingestion.keytab
```

So với `application.properties` trên nhánh PR, chỉ khác 5 dòng: `enabled`, `bootstrap-servers[0]`,
`principal`, `key-tab`, và tên host. Bốn dòng security còn lại đã đúng sẵn.

### 4.1. Service chạy trực tiếp trên máy (IDE / `java -jar`)

```bash
sudo cp client/krb5.conf /etc/krb5.conf          # JVM đọc path này mặc định, KHÔNG cần -D
sudo mkdir -p /etc/kafka && sudo cp ingestion.keytab /etc/kafka/
echo "127.0.0.1  kafka.kafka.local kdc.kafka.local" | sudo tee -a /etc/hosts
```

### 4.2. Service chạy trong Docker

Cho container của service vào chung network để phân giải được hostname:

```yaml
services:
  promotion-ingestion:
    # ...
    volumes:
      - ./client/krb5.conf:/etc/krb5.conf:ro
      - ./ingestion.keytab:/etc/kafka/ingestion.keytab:ro
    networks:
      - promix-local

networks:
  promix-local:
    external: true
    name: promotion-phase2-local_promix-local
```

> Network của stack Kerberos đã đổi sang dùng chung với `promotion-phase2-local`;
> tên `kafka-kerberos-net` không còn tồn tại. Muốn chạy service bằng Docker thay vì
> bằng Maven thì xem **CHAY-INGESTION-DOCKER.md**, có sẵn compose dùng image.

Trong docker, `kafka.kafka.local` tự phân giải qua network alias — không cần sửa `/etc/hosts`.

### 4.3. Lên Kubernetes (phần "Needs DevOps" của PR)

```yaml
volumeMounts:
  - { name: krb5-config,      mountPath: /etc/krb5.conf,            subPath: krb5.conf, readOnly: true }
  - { name: ingestion-keytab, mountPath: /etc/kafka/ingestion.keytab, subPath: keytab,  readOnly: true }
volumes:
  - name: krb5-config
    configMap: { name: krb5-config }
  - name: ingestion-keytab
    secret: { secretName: ingestion-keytab, defaultMode: 0400 }
```

`krb5.conf` → ConfigMap (không bí mật). Keytab → **Secret**, `defaultMode: 0400`, và phải đọc được
bởi user runtime của container. Mở egress tới KDC: TCP+UDP **88**, và **464** nếu sau này dùng
`kpasswd`.

---

## 5. Test end-to-end

**Thứ tự quan trọng** — xem mục 6.2 để biết vì sao.

```bash
# 1) Khởi động service với cấu hình ở mục 4, chờ log:
#    === BI/Data Kafka Consumer Configuration ===
#    Security Protocol: SASL_PLAINTEXT / SASL Mechanism: GSSAPI

# 2) Bơm một event mẫu — đúng envelope mà BiDataKafkaConfig.extractEventType() mong đợi
docker exec kafka-client bash -c 'cat > /tmp/ing.properties <<EOF
security.protocol=SASL_PLAINTEXT
sasl.mechanism=GSSAPI
sasl.kerberos.service.name=kafka
sasl.jaas.config=com.sun.security.auth.module.Krb5LoginModule required useKeyTab=true storeKey=true keyTab="/krb/ingestion.keytab" principal="ingestion@KAFKA.LOCAL";
EOF
echo "{\"eventId\":\"evt-0001\",\"occurredAt\":\"2026-11-07T06:20:00Z\",\"data\":{\"segmentId\":\"SEG-001\",\"sourceId\":\"SRC-001\",\"operator\":\"IN\",\"promotionDate\":\"2026-11-07\"}}" \
  | kafka-console-producer --bootstrap-server kafka.kafka.local:9094 \
      --producer.config /tmp/ing.properties --topic promotion_platform_bi_events'

# 3) Log service phải có:  [BI_DATA] Received 1 messages
```

Kiểm tra sức khỏe và DLQ:

```bash
curl -s localhost:8080/actuator/health | jq '.components.biDataDlqHealthIndicator'
```

`biDataDlqHealthIndicator` **DOWN** nghĩa là có partition đang kẹt retry việc ghi DLQ — theo thiết
kế của PR, retry này **không giới hạn** để khỏi mất bản ghi. Đây là tín hiệu cụm **nội bộ** chết,
không phải cụm BI/Data.

Xem topic và message trên UI: **http://localhost:8080** (Kafka UI của stack).

---

## 6. Cạm bẫy — đọc kỹ phần này

### 6.1. Stack này KHÔNG thay thế cụm Kafka nội bộ

`BiDataKafkaConfig.biDataDlqRecoverer()` ghi DLQ qua `InternalEventProducer`, mà producer đó nối
cụm **do promix-messaging starter quản lý** (`promix.messaging.kafka.*`, SASL/PLAIN, user `admin`),
**không phải** cụm Kerberos này. Kiến trúc lúc chạy là **hai cụm song song**:

```
cụm BI/Data (Kerberos, stack này)  ──► BiDataEventConsumer ──► ProcessExternalEventUsecase
                                                                      │
cụm nội bộ (promix starter, PLAIN) ◄── InternalEventProducer ◄────────┘  (output + DLQ)
```

Tắt cụm nội bộ thì consumer vẫn nhận được message nhưng **không xuất được gì**, và sẽ kẹt retry DLQ
vô hạn. Phải chạy cả hai.

### 6.2. `auto-offset-reset=latest` — bơm message trước là không thấy gì

PR cố ý đặt `latest` (xem Javadoc: tránh replay toàn bộ lịch sử của cụm người khác thành giao dịch
ví). Hệ quả khi test: nếu bạn produce **trước** khi service kết nối lần đầu, consumer group mới sẽ
bắt đầu từ cuối topic và **bỏ qua** đúng những message đó. Luôn khởi động service trước, chờ log
`Received`, rồi mới produce. Lỡ rồi thì:

```bash
docker exec kafka-client kafka-consumer-groups --bootstrap-server kafka.kafka.local:9094 \
  --command-config /krb/client.properties --group ingestion-bi-data-group \
  --reset-offsets --to-earliest --topic promotion_platform_bi_events --execute   # service phải đang DỪNG
```

### 6.3. Hostname, không bao giờ là IP

Kerberos tra service principal theo hostname trong `bootstrap-servers`. Điền `172.46.3.38:9094` sẽ
nhận `Server not found in Kerberos database`, vì không có SPN `kafka/172.46.3.38@KAFKA.LOCAL`.
Luôn dùng `kafka.kafka.local:9094`.

### 6.4. `protocol` và `mechanism` phải cùng có hoặc cùng không

`addSecurityConfig()` ném `IllegalStateException` khi chỉ set một trong hai — cố ý, để một cấu hình
nửa vời không âm thầm rơi về PLAINTEXT. Đừng comment một dòng ra để "tạm tắt Kerberos".

### 6.5. Principal và keytab không được chứa `"` hay `\`

`requireNonBlankJaasValue()` chặn cả hai ký tự, vì chúng phá cú pháp mệnh đề JAAS. Đường dẫn Linux
bình thường thì không sao; đường dẫn kiểu Windows (`C:\...`) sẽ bị từ chối ngay lúc khởi động.

### 6.6. Validate chỉ ở mức cú pháp, không phải pre-flight

`DefaultKafkaConsumerFactory` lazy — principal sai, keytab thiếu, `krb5.conf` không có thì app
**vẫn khởi động xanh**, lỗi GSSAPI chỉ nổ ở lần poll đầu tiên. Đừng tin vào việc "app start được
là Kerberos OK"; phải nhìn log có dòng `[BI_DATA] Received`.

### 6.7. Thiếu `EventSchema` là rơi DLQ hết

Pipeline tra `EventSchema` theo event type. Chạy Liquibase (đặc biệt
`v006/018-update-bi-events-source-topic-pattern.xml` của PR) trước khi test, không thì mọi message
đều rơi vào `promotion_external_dlq`.

### 6.8. Lệch giờ quá 5 phút là hỏng

Kerberos từ chối vé lệch giờ. Nếu service chạy trong VM/WSL hay bị trôi giờ: `sudo timedatectl set-ntp true`.

---

## 7. Checklist trước khi bật ở môi trường chung

- [ ] Đã test xanh với stack local (mục 5)
- [ ] Đội BI/Data xác nhận: realm, KDC host, tên topic thật, `service-name`, `SASL_PLAINTEXT` hay `SASL_SSL`
- [ ] Đội BI/Data xác nhận quy ước `data.operator` IN/OUT khớp `extractEventType()`
- [ ] Keytab thật cấp dưới dạng Secret, không nằm trong image hay git
- [ ] Jenkinsfile trong `cicd` đã copy config mới vào build context (PR có nhắc)
- [ ] Mở egress tới KDC: 88/tcp, 88/udp (+464 nếu cần)
- [ ] Nếu BI/Data dùng `SASL_SSL`: thêm truststore, `security.protocol=SASL_SSL` — stack local đang là `SASL_PLAINTEXT`, **đây là điểm khác biệt duy nhất mà test local không phủ được**
- [ ] `bi-data.enabled=true` chỉ bật sau khi tất cả mục trên xong

Hai việc PR tự đánh dấu là không chặn, nhưng nên biết: `docs/tech-debt.md` mục #7 (DLQ ghi
fire-and-forget), và vênh tên topic sẵn có giữa `promotion_segment_change_events` với consumer thật
của `promotion-segment` (`promotion_segment_command`).
