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
git clone https://github.com/namakamu/postgres-cdc-clickhouse.git
cd postgres-cdc-clickhouse
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

```bash
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @debezium.json
```

Contoh isi file `debezium.json`:

```json
{
  "name": "shop-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "plugin.name": "pgoutput",
    "database.hostname": "postgres",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "postgres",
    "database.server.name": "shop",
    "table.include.list": "public.users",
    "database.history.kafka.bootstrap.servers": "kafka:9092",
    "database.history.kafka.topic": "schema-changes.shop",
    "tasks.max": "1",
    "snapshot.mode": "initial",
    "topic.prefix": "shop",
    "topic.creation.enable": "true",
    "topic.creation.default.partitions": "1",
    "topic.creation.default.replication.factor": "1",
    "topic.creation.default.cleanup.policy": "delete",
    "topic.creation.default.retention.ms": "604800000",
    "database.history.skip.unparseable.ddl": "true",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter": "io.confluent.connect.avro.AvroConverter",
    "value.converter.schema.registry.url": "http://schema-registry:8081",
    "key.converter.schema.registry.url": "http://schema-registry:8081",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState"
  }
}
```

---

### 🔹 Step 3: Konfigurasi ClickHouse

1. **Buat database dan tabel utama:**

```sql
CREATE DATABASE shop;

CREATE TABLE shop.users
(
    user_id UInt32,
    username String,
    account_type String,
    updated_at DateTime,
    created_at DateTime,
    operation_type String,
    kafka_time Nullable(DateTime),
    kafka_offset UInt64
)
ENGINE = ReplacingMergeTree
ORDER BY (user_id, updated_at);
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
    created_at UInt64,
    __op String
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'broker:29092',
         kafka_topic_list = 'shop.public.users',
         kafka_group_name = 'clickhouse',
         kafka_format = 'AvroConfluent',
         format_avro_schema_registry_url = 'http://schema-registry:8081';
```

3. **Buat materialized view untuk konsumsi data Kafka:**

```sql
CREATE MATERIALIZED VIEW kafka_shop.consumer__users TO shop.users AS
SELECT
    user_id,
    username,
    account_type,
    toDateTime(updated_at / 1000000) AS updated_at,
    toDateTime(created_at / 1000000) AS created_at,
    CASE __op
        WHEN 'c' THEN 'create'
        WHEN 'u' THEN 'update'
        WHEN 'd' THEN 'delete'
        ELSE 'unknown'
    END AS operation_type,
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

## 🧠 Catatan

* Kamu bisa menambahkan lebih banyak tabel PostgreSQL ke CDC hanya dengan menambahkan ke `table.include.list` di config Debezium.
* Untuk performa maksimal, pertimbangkan setting `flush_interval_ms` dan `batch_size` di Kafka & ClickHouse.
* Bisa dikembangkan lebih lanjut untuk tujuan observability, notifikasi real-time, hingga pemrosesan stream analitik.

---
