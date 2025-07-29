# 🐘📡 Real-time CDC Pipeline: PostgreSQL → Kafka → ClickHouse

Repositori ini menyajikan implementasi **Change Data Capture (CDC)** real-time dari PostgreSQL ke ClickHouse menggunakan Kafka sebagai perantara. Sistem ini memungkinkan Anda *stream* perubahan data (insert, update, delete) secara langsung ke ClickHouse untuk analitik real-time.

Proyek ini menggunakan teknologi:
- **Debezium** untuk CDC
- **Kafka** untuk event streaming
- **Schema Registry** untuk validasi schema Avro
- **ClickHouse Kafka Engine** untuk konsumsi langsung stream
- **Docker Compose** untuk kemudahan setup

---

## 🧭 Arsitektur Sistem

```mermaid
graph TD
    A[PostgreSQL] -- CDC (WAL) --> B(Debezium Connector)
    B --> C[Kafka Broker]
    C --> D[Schema Registry]
    C --> E[ClickHouse Kafka Engine Table]
    E --> F[Materialized View]
    F --> G[ClickHouse Final Table]
````

> PostgreSQL mencatat perubahan ke WAL, dibaca oleh Debezium dan dikirim ke Kafka. Schema Registry menyimpan schema Avro, lalu ClickHouse Kafka Engine membaca stream-nya dan menyimpan ke tabel akhir.

---

## 🧩 Komponen Utama

| Service             | Fungsi                                |
| ------------------- | ------------------------------------- |
| 🔁 Zookeeper        | Koordinasi Kafka Broker               |
| 📬 Kafka Broker     | Menyalurkan stream data               |
| 🔎 Debezium         | Mendeteksi perubahan PostgreSQL       |
| 📜 Schema Registry  | Menyimpan dan validasi schema Avro    |
| 🌐 Kafka REST Proxy | Antarmuka REST untuk Kafka (opsional) |
| 🧮 PostgreSQL       | Sumber data utama                     |
| 📊 ClickHouse       | Tujuan akhir data analitik            |
| 🧭 Redpanda Console | UI visual untuk observasi Kafka       |

---

## 📦 Prasyarat

* Docker
* Docker Compose

---

## 🚀 Menjalankan Sistem

### 1. Clone Repository

```bash
git clone https://github.com/rynkoemi/postgre-to-clickhouse
cd postgre-to-clickhouse
```

> Mengambil semua file proyek dan berpindah ke direktori kerja.

---

### 2. Build Custom Debezium Image

```bash
docker build -t custom-connect .
```

> Membangun image Kafka Connect dengan dukungan Debezium + Avro.

---

### 3. Jalankan Seluruh Stack

```bash
docker-compose up -d
```

> Menjalankan semua layanan secara bersamaan (PostgreSQL, Kafka, Debezium, ClickHouse, dsb).

---

## 🔧 Konfigurasi Sistem

### 🔹 Step 1: Setup PostgreSQL

```bash
docker exec -it postgres psql -U postgres
```

> Masuk ke shell PostgreSQL.

```sql
CREATE TABLE users (
    user_id SERIAL PRIMARY KEY,
    username VARCHAR(50),
    account_type VARCHAR(20),
    updated_at TIMESTAMP DEFAULT timezone('UTC', CURRENT_TIMESTAMP),
    created_at TIMESTAMP DEFAULT timezone('UTC', CURRENT_TIMESTAMP)
);
```

> Membuat tabel `users` dengan informasi dasar dan timestamp otomatis.

```sql
INSERT INTO users (username, account_type) VALUES
('user1', 'Bronze'),
('user2', 'Silver'),
('user3', 'Gold');
```

> Menambahkan data awal untuk menguji pipeline.

---

### 🔹 Step 2: Deploy Debezium Connector

```bash
curl --location --request POST 'http://localhost:8083/connectors' \
--header 'Content-Type: application/json' \
--data-raw '{
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
    "database.history.kafka.bootstrap.servers": "kafka:9092",
    "database.history.kafka.topic": "schema-changes.shop",
    "table.include.list": "public.users",
    "snapshot.mode": "initial",
    "key.converter": "io.confluent.connect.avro.AvroConverter",
    "value.converter": "io.confluent.connect.avro.AvroConverter",
    "key.converter.schema.registry.url": "http://schema-registry:8081",
    "value.converter.schema.registry.url": "http://schema-registry:8081",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "tasks.max": "1"
  }
}'
```

> Menghubungkan Debezium dengan PostgreSQL dan Kafka, hanya memonitor tabel `users`. Avro digunakan agar format data terstruktur dan tervalidasi.

---

### 🔹 Step 3: Setup ClickHouse

```bash
docker exec -it clickhouse clickhouse-client
```

> Masuk ke CLI ClickHouse.

#### a. Tabel Final

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
ORDER BY (user_id, updated_at);
```

> Tabel utama untuk menyimpan data akhir. `ReplacingMergeTree` akan otomatis menimpa versi data yang lebih lama berdasarkan timestamp.

---

#### b. Kafka Source Table

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

> Tabel ini otomatis membaca data dari topic Kafka `shop.public.users` menggunakan format Avro dari Schema Registry.

---

#### c. Materialized View

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

> View ini akan membaca setiap baris dari `kafka__users`, mengubah timestamp dari mikrodetik ke detik (`DateTime`), lalu memasukkannya ke tabel `shop.users`.

---

#### d. Verifikasi

```sql
SELECT * FROM shop.users;
```

> Cek apakah data dari PostgreSQL berhasil masuk ke ClickHouse.

---

## 📊 Monitoring

| Tool               | URL Lokal                                      | Fungsi                               |
| ------------------ | ---------------------------------------------- | ------------------------------------ |
| Redpanda Console   | [http://localhost:9080](http://localhost:9080) | Lihat pesan Kafka                    |
| Schema Registry UI | [http://localhost:8081](http://localhost:8081) | Validasi dan lihat schema Avro       |
| Kafka REST Proxy   | [http://localhost:8082](http://localhost:8082) | Kirim/ambil pesan Kafka via REST API |

---

## ⚙️ Konfigurasi Penting

* PostgreSQL sudah menggunakan `wal_level=logical` di dalam container.
* Schema Avro membantu sinkronisasi struktur data antara producer dan consumer.
* Semua koneksi dan port diatur di file `docker-compose.yml`.

---

## ❓ FAQ

**Q: Mengapa data tidak muncul di ClickHouse?**
Cek urutan berikut:

* Connector aktif (`localhost:8083/connectors`)
* Kafka topic `shop.public.users` memiliki data
* Tabel Kafka dan Materialized View di ClickHouse sudah dibuat

**Q: Bagaimana saya melihat isi Kafka topic?**
Gunakan Redpanda Console di `http://localhost:9080`

**Q: Ingin menambahkan tabel lain?**
Tambahkan di `table.include.list` connector Debezium dan buat tabel Kafka + View baru di ClickHouse.

---

