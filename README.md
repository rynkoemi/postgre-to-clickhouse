# 🐘📡 Real-time CDC Pipeline: PostgreSQL → Kafka → ClickHouse

Repositori ini berisi arsitektur lengkap untuk implementasi **Change Data Capture (CDC)** dari PostgreSQL ke Kafka, kemudian mengalirkan data ke ClickHouse secara real-time. Proyek ini menggunakan teknologi modern seperti Debezium, Kafka, Schema Registry, dan ClickHouse Kafka Engine — semuanya dikemas dalam satu `docker-compose.yml`.

---

## 🧩 Komponen Utama

| Service                 | Deskripsi                                                            |
| ----------------------- | -------------------------------------------------------------------- |
| 🔁 **Zookeeper**        | Koordinator cluster Kafka.                                           |
| 📬 **Kafka Broker**     | Message broker untuk menyalurkan stream data.                        |
| 🔎 **Debezium**         | CDC engine untuk mendeteksi perubahan data dari PostgreSQL ke Kafka. |
| 📜 **Schema Registry**  | Manajemen schema Avro untuk payload Kafka.                           |
| 🌐 **Kafka REST Proxy** | Antarmuka RESTful untuk Kafka (opsional).                            |
| 🧮 **PostgreSQL**       | Sumber data asli (source database).                                  |
| 📊 **ClickHouse**       | Database tujuan dengan dukungan stream via Kafka Engine.             |
| 🧭 **Redpanda Console** | UI Kafka modern untuk eksplorasi dan observasi topik secara visual.  |

---

## 📦 Prasyarat

* Docker
* Docker Compose

---

## 🚀 Cara Menjalankan

1. **Clone repository ini:**

```bash
git clone  https://github.com/rynkoemi/postgre-to-clickhouse
cd postgre-to-clickhouse
```

2. **Build custom image Debezium (untuk dukungan Avro):**

```bash
docker build -t custom-connect .
```

3. **Jalankan semua service:**

```bash
docker-compose up -d
```

---

## 🔧 Langkah Konfigurasi

### 🔹 Step 1: Setup PostgreSQL

Masuk ke dalam container PostgreSQL:

```bash
docker exec -it postgres psql -U postgres
```

Lalu buat tabel `users`:

```sql
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL,
    account_type VARCHAR(20) NOT NULL,
    updated_at TIMESTAMP DEFAULT timezone('UTC', CURRENT_TIMESTAMP),
    created_at TIMESTAMP DEFAULT timezone('UTC', CURRENT_TIMESTAMP)
);

INSERT INTO users (username, account_type) VALUES
('user1', 'Bronze'),
('user2', 'Silver'),
('user3', 'Gold');
```

---

### 🔹 Step 2: Konfigurasikan Debezium Connector

Kirim konfigurasi connector ke Kafka Connect REST API:

```json
curl --location --request POST 'http://localhost:8083/connectors' \
--header 'Content-Type: application/json' \
--data-raw '{
    "name": "shop-connector",
    "config": {
        "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
        "database.dbname": "postgres",
        "database.history.kafka.bootstrap.servers": "kafka:9092",
        "database.history.kafka.topic": "schema-changes.shop",
        "database.hostname": "postgres",
        "database.password": "postgres",
        "database.port": "5432",
        "database.server.name": "shop",
        "database.user": "postgres",
        "name": "shop-connector",
        "plugin.name": "pgoutput",
        "table.include.list": "public.users",
        "tasks.max": "1",
        "topic.creation.default.cleanup.policy": "delete",
        "topic.creation.default.partitions": "1",
        "topic.creation.default.replication.factor": "1",
        "topic.creation.default.retention.ms": "604800000",
        "topic.creation.enable": "true",
        "topic.prefix": "shop",
        "database.history.skip.unparseable.ddl": "true",
        "value.converter": "io.confluent.connect.avro.AvroConverter",
        "key.converter": "io.confluent.connect.avro.AvroConverter",
        "value.converter.schema.registry.url": "http://schema-registry:8081",
        "key.converter.schema.registry.url": "http://schema-registry:8081",
        "transforms": "unwrap",
        "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
        "snapshot.mode": "initial"
    }
}'
```

---

### 🔹 Step 3: Konfigurasi ClickHouse

1. **Buat database dan tabel utama:**

Masuk ke ClickHouse:

```bash
docker exec -it clickhouse clickhouse-client
```

```sql
CREATE DATABASE shop;

CREATE TABLE shop.users
(
    user_id UInt32,
    username String,
    account_type String,
    updated_at DateTime,
    created_at DateTime,
    kafka_time Nullable(DateTime),
    kafka_offset UInt64
)
ENGINE = ReplacingMergeTree
ORDER BY (user_id, updated_at)
SETTINGS index_granularity = 8192;
```

2. **Buat Kafka Engine Table (source streaming):**

```sql
CREATE DATABASE kafka_shop;

CREATE TABLE kafka_shop.kafka__users
(
    user_id UInt32,
    username String,
    account_type String,
    updated_at UInt64,
    created_at UInt64
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'broker:29092',
kafka_topic_list = 'shop.public.users',
kafka_group_name = 'clickhouse',
kafka_format = 'AvroConfluent',
format_avro_schema_registry_url='http://schema-registry:8081';
```

3. **Buat materialized view untuk konsumsi data Kafka:**

```sql
CREATE MATERIALIZED VIEW kafka_shop.consumer__users TO shop.users
(
    user_id UInt32,
    username String,
    account_type String,
    updated_at DateTime,
    created_at DateTime,
    kafka_time Nullable(DateTime),
    kafka_offset UInt64
) AS
SELECT
    user_id,
    username,
    account_type,
    toDateTime(updated_at / 1000000) AS updated_at,
    toDateTime(created_at / 1000000) AS created_at,
    _timestamp AS kafka_time,
    _offset AS kafka_offset
FROM kafka_shop.kafka__users;
```

4. **Verifikasi data:**

```sql
SELECT * FROM shop.users;
```

---

## 📊 Monitoring

* 🖥 **Redpanda Console** → `http://localhost:9080`
  Monitor Kafka topics dan isi pesan secara real-time.

* 📘 **Schema Registry UI** → `http://localhost:8081`
  Melihat schema Avro yang digunakan oleh Kafka.

* 🔁 **Kafka REST Proxy** → `http://localhost:8082`
  Tes API Kafka REST untuk publish/consume topik.

---

## ⚙️ Konfigurasi Tambahan

* `docker-compose.yml` mencakup semua environment variabel, port, dependencies antar service.
* PostgreSQL sudah dikonfigurasi `wal_level = logical` untuk mendukung CDC.
* Debezium memanfaatkan **Avro + Schema Registry** agar schema message fleksibel dan dapat divalidasi.

---
