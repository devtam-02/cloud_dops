# ELK — Elasticsearch + Logstash + Kibana

| Thành phần | Cổng host | Ghi chú |
|---|---|---|
| Elasticsearch 8.15.2 | 9200 | bảo mật BẬT, user `elastic` |
| Kibana | 5601 | đăng nhập bằng `elastic` |
| Logstash | 5044 (Beats), 5000 (TCP JSON), 9600 (API) | |

Tất cả bind `0.0.0.0` nên gọi được từ máy khác trong mạng.

## Chạy

```bash
cp .env.example .env
# Sinh khoá mã hoá cho Kibana:
sed -i "s|^KIBANA_ENCRYPTION_KEY=.*|KIBANA_ENCRYPTION_KEY=$(openssl rand -hex 32)|" .env
# Đổi ELASTIC_PASSWORD và KIBANA_SYSTEM_PASSWORD trong .env

docker compose up -d
docker compose logs -f elasticsearch
```

Network `microservice-local` khai `external`. Chạy ELK một mình (chưa chạy `../keycloak`) thì
tạo trước:

```bash
docker network create microservice-local
```

Kibana: `http://<IP-máy-chủ>:5601`, user `elastic`, mật khẩu là `ELASTIC_PASSWORD`.

## `es-setup` làm gì

Container chạy một lần rồi thoát, đặt mật khẩu cho user hệ thống `kibana_system`.

Từ Elasticsearch 8.x, Kibana **không được** kết nối bằng user `elastic` (superuser) — Elastic
chặn. Phải dùng `kibana_system`, mà mật khẩu user này **không** đặt được bằng biến môi trường
như `ELASTIC_PASSWORD`; bắt buộc gọi API sau khi ES đã chạy. Kibana `depends_on` bước này với
`condition: service_completed_successfully` nên thứ tự luôn đúng.

## Gửi log vào

**Từ app Spring Boot** (`logstash-logback-encoder`), qua cổng TCP 5000:

```xml
<appender name="LOGSTASH" class="net.logstash.logback.appender.LogstashTcpSocketAppender">
    <destination>logstash:5000</destination>
    <encoder class="net.logstash.logback.encoder.LogstashEncoder"/>
</appender>
```

App chạy trong Docker thì dùng `logstash:5000` (cùng network `microservice-local`); chạy ngoài
thì dùng `<IP-máy-chủ>:5000`.

**Thử nhanh không cần app:**

```bash
echo '{"message":"hello elk","level":"INFO","service":"test"}' | nc <IP> 5000
curl -s -u elastic:'<mật khẩu>' "http://<IP>:9200/logs-*/_search?size=1&pretty"
```

**Từ Filebeat / Elastic Agent:** trỏ output về `<IP>:5044`.

Pipeline nằm ở `logstash/pipeline/logstash.conf`, sửa xong chỉ cần
`docker compose restart logstash`. Index mặc định là `logs-%{+YYYY.MM.dd}`.

## Yêu cầu của máy chủ

**`vm.max_map_count` ≥ 262144.** Thiếu là Elasticsearch chết ngay lúc khởi động với
`max virtual memory areas vm.max_map_count [65530] is too low`:

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
```

**RAM.** Mặc định ES 512m + Logstash 256m heap, cộng Kibana khoảng 1GB — cần tối thiểu ~3GB
trống. Chỉnh `ES_JAVA_OPTS` / `LS_JAVA_OPTS` trong `.env`.

**Dung lượng đĩa.** Elasticsearch từ chối ghi khi đĩa đầy quá ngưỡng (mặc định 85% chuyển
index sang read-only). Đĩa đầy còn làm ES chết ngay lúc khởi động với
`FileSystemException: /tmp/elasticsearch-...: No space left on device`.

## Lưu ý về cổng

Cổng 9200 có thể đụng với Elasticsearch của stack khác (ví dụ `promotion/infrastructure`).
Chạy đồng thời thì đổi `ELASTIC_PORT` trong `.env`.

## Trước khi dùng thật

1. Đổi `ELASTIC_PASSWORD`, `KIBANA_SYSTEM_PASSWORD`, sinh lại `KIBANA_ENCRYPTION_KEY`.
   Khoá mã hoá mà đổi sau khi đã dùng thì các saved object đã mã hoá (alert, connector)
   không đọc lại được.
2. Bật TLS (`xpack.security.http.ssl.enabled`) hoặc đặt sau reverse proxy. Hiện tại mật khẩu
   `elastic` đi qua HTTP ở dạng rõ — chỉ chấp nhận được trong mạng nội bộ tin cậy.
3. Đổi `ELASTIC_BIND` thành `127.0.0.1` nếu không cần truy cập ES từ máy khác; Kibana vẫn
   gọi được vì nó đi qua network nội bộ của Docker.
4. Đặt ILM policy để log cũ tự xoá, nếu không index sẽ phình tới khi đầy đĩa.

## Chưa kiểm chứng

Stack này **chưa chạy thử được** trên máy dựng nó: ổ đĩa hệ thống đầy 100% nên Elasticsearch
dừng ở `No space left on device`. Cấu hình compose đã `docker compose config` hợp lệ và các
lựa chọn (bảo mật bật, `es-setup` cho `kibana_system`, healthcheck) đều theo tài liệu chính
thức của Elastic 8.x, nhưng chưa có bằng chứng chạy thật. Dọn đĩa xong nên chạy lại và đối
chiếu mục "Thử nhanh" ở trên.
