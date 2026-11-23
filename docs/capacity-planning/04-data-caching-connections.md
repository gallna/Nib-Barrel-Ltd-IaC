## Sekcja 4: Warstwa Danych, Buforowanie i Zarządzanie Połączeniami

### 4.1. Architektura Baz Relacyjnych — Amazon Aurora Global Database

Zamiast klasycznego Amazon RDS (gdzie replikacja między regionami opiera się na wolniejszym przesyłaniu logów binarnych/WAL i często łamie rygorystyczne RPO przy dużym ruchu zapisu), wybieramy **Amazon Aurora** z funkcją **Global Database**:

* **Replikacja na poziomie pamięci masowej (Storage-Level Replication):** Aurora replikuje bloki danych bezpośrednio między warstwą dyskową w `eu-central-1` a `eu-west-1` z typowym opóźnieniem **poniżej 1 sekundy** (ogromny zapas wobec naszego limitu **RPO ≤ 5 min**), nie obciążając procesorów instancji *Writer*.
* **Tryb Aurora I/O-Optimized:** Przy 41,2k req/s na `/stats` i ciągłych zapisach wsadowych, standardowy rozliczeniowy model I/O generuje nieprzewidywalne koszty i dławienie przepustowości. *I/O-Optimized* zapewnia wyższą przepustowość zapisu i niższe opóźnienia p99.
* **Izolacja per API (4 osobne klastry):** Każdy z 4 interfejsów API dostaje własny, niezależny klaster Aurora. Nawet jeśli w *Agrippa Mosa 2* pojawi się zoptymalizowane źle zapytanie na API #3, nie wpłynie ono na *Pythodorus 3* (API #1) ani płatności w *Dienekes Plaza* (API #4).

#### Dobór klas instancji i replik odczytowych (Region Główny `eu-central-1` vs DR `eu-west-1`):

| Klaster DB | Silnik | MAU | Instancja Primary (Writer) `eu-central-1` | Repliki Odczytowe (Readers) `eu-central-1` | Instancje Warm Standby `eu-west-1` | Uzasadnienie wymiarowania |
| --- | --- | --- | --- | --- | --- | --- |
| **`aurora-api-1`** | Aurora PostgreSQL 16 | 75,0M | `db.r8g.16xlarge` (64 vCPU, 512 GB RAM) | **2x** `db.r8g.12xlarge` (po 48 vCPU, 384 GB) | **1x** `db.r8g.16xlarge` (Headless/Reader) | Buforuje w pamięci aktywne indeksy 6,45M DAU; dwie repliki w innych AZ przejmują odczyty raportowe i failover w < 30s. |
| **`aurora-api-2`** | Aurora PostgreSQL 16 | 1,0M | `db.r8g.xlarge` (4 vCPU, 32 GB RAM) | **1x** `db.r8g.xlarge` (4 vCPU, 32 GB RAM) | **1x** `db.r8g.xlarge` | Mała baza, ale wymóg HA (Multi-AZ) i RTO 15 min wymaga aktywnej repliki w drugiej AZ i węzła w Irlandii. |
| **`aurora-api-3`** | Aurora PostgreSQL 16 | 52,0M | `db.r8g.12xlarge` (48 vCPU, 384 GB RAM) | **2x** `db.r8g.8xlarge` (po 32 vCPU, 256 GB) | **1x** `db.r8g.12xlarge` | Obsługuje 2 gry; 384 GB RAM mieści gorący zestaw danych (*working set*) tabel profili i ekwipunku. |
| **`aurora-api-4`** | Aurora MySQL 8.0 | 6,0M | `db.r8g.4xlarge` (16 vCPU, 128 GB RAM) | **1x** `db.r8g.4xlarge` (16 vCPU, 128 GB RAM) | **1x** `db.r8g.4xlarge` | Dedykowana pod silnik MySQL dla wersji Android + Web; osobna replika izoluje zapytania przeglądarkowe BFF. |

*(Wskazówka operacyjna: w regionie DR `eu-west-1` utrzymujemy pełnowymiarową instancję repliki w trybie Warm Standby. Podczas przełączania awaryjnego nie tracimy 8–10 minut na skalowanie maszyny w górę — instancja jest od razu gotowa na pełny ruch produkcyjny).*

---

### 4.2. Zarządzanie Pulą Połączeń — Amazon RDS Proxy

Przy 273 kontenerach Fargate w szczycie, gdyby każdy kontener otworzył choćby 20 połączeń do bazy danych, Aurora otrzymałaby ponad **5 400 jednoczesnych sesji TCP**. W PostgreSQL każdy backend process zużywa pamięć i narzuca narzut przełączania kontekstu, a podczas nagłego failoveru bazy zrywanie tysięcy połączeń powoduje kilkudziesięciosekundowe zawieszenie aplikacji.

* **Decyzja:** Przed każdym klastrem Aurora (zarówno w `eu-central-1`, jak i `eu-west-1`) wdrażamy **Amazon RDS Proxy** z dwoma punktami końcowymi:
* **Read/Write Endpoint:** kieruje ruch wyłącznie z serwisów `payments` oraz workerów zapisujących paczki `/stats`.
* **Read-Only Endpoint:** rozkłada zapytania odczytowe na repliki *Aurora Readers*.


* **Korzyści krytyczne dla SLI 99,5%:**
* **Connection Multiplexing:** tysiące połączeń z ECS są multipleksowane na kilkadziesiąt stałych, rozgrzanych połączeń do bazy danych.
* **Sub-second Failover Masking:** podczas awarii instancji *Writer* w Aurorze, RDS Proxy wstrzymuje przychodzące zapytania w kolejce (zamiast rzucać błędami połączenia do ECS) i automatycznie przepina je na nowo wypromowaną replikę w ciągu **1–3 sekund**.



---

### 4.3. Warstwa Cache i Odciążenie Odczytów — Amazon ElastiCache (Valkey)

Ścieżka `/stats` generuje **41 219 req/s**. Bez agresywnego buforowania w pamięci operacyjnej żadna baza relacyjna nie utrzyma opóźnienia **p99 < 150 ms** przy tej skali.

* **Wybór silnika:** **Amazon ElastiCache for Valkey 8** (w pełni kompatybilny z Redisem open-source silnik wspierany przez AWS, oferujący wyższą przepustowość wielowątkową I/O).
* **Architektura:** **Cluster Mode Enabled (Multi-AZ)** z automatycznym przełączaniem (*Automatic Failover*) i szyfrowaniem w tranzycie (TLS) oraz spoczynku (KMS). Dedykowany klaster cache dla każdego z 4 API.

#### Dimensioning klastrów ElastiCache (Valkey) w regionie głównym:

| Klaster Cache | Obsługiwane API | Liczba Shardów | Repliki / Shard | Typ Węzła (Graviton) | Łączna Pamięć RAM | Zastosowanie |
| --- | --- | --- | --- | --- | --- | --- |
| **`valkey-api-1`** | API #1 (75M MAU) | 6 | 2 (Multi-AZ) | `cache.r7g.2xlarge` (52 GB) | **312 GB** | Profile graczy, rankingi (Sorted Sets), liczniki sesji, rate-limiting. |
| **`valkey-api-2`** | API #2 (1M MAU) | 1 | 2 (Multi-AZ) | `cache.r7g.large` (13 GB) | **13 GB** | Statystyki i sesje dla *Theognis per Megara*. |
| **`valkey-api-3`** | API #3 (52M MAU) | 4 | 2 (Multi-AZ) | `cache.r7g.2xlarge` (52 GB) | **208 GB** | Rozdzielone prefiksy kluczy (`g1:`, `g2:`) dla obu gier *Agrippa Mosa*. |
| **`valkey-api-4`** | API #4 (6M MAU) | 2 | 2 (Multi-AZ) | `cache.r7g.xlarge` (26 GB) | **52 GB** | Współdzielony stan gracza Android + Web oraz tokeny sesji BFF. |

---

### 4.4. Partycjonowanie i Zarządzanie Cyklem Życia Danych (75M+ kont)

W bazach o wielkości kilkudziesięciu milionów aktywnych graczy pojedyncza tabela `player_stats_history` lub `payment_transactions` szybko urośnie do terabajtów, degradując wydajność indeksów B-Tree i operacji `VACUUM` w PostgreSQL.

1. **Deklaratywne Partycjonowanie Czasowe (`PARTITION BY RANGE`):**
* Tabele zdarzeń, historii meczów oraz logów płatności dzielimy na partycje miesięczne (zarządzane automatycznie przez rozszerzenie `pg_partman` w PostgreSQL oraz harmonogramy zdarzeń w MySQL).
* Tabele profili graczy (`players`, `player_balances`) o wysokim współczynniku aktualizacji (`UPDATE`) w PostgreSQL konfigurujemy z **`fillfactor = 80`**, aby wymusić optymalizację **HOT (Heap-Only Tuples)** i uniknąć fragmentacji indeksów.


2. **Archiwizacja Zimnych Danych (Tiered Storage):**
* Partycje starsze niż **90 dni** są cyklicznie eksportowane w formacie **Apache Parquet** do **Amazon S3 (Glacier Instant Retrieval)** do celów audytowych i analitycznych, a następnie bezpiecznie odpinane (`DETACH PARTITION`) z produkcyjnej bazy Aurora. Utrzymuje to rozmiar bazy operacyjnej w ryzach i gwarantuje błyskawiczne przywracanie kopii zapasowych.



---

### 4.5. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 4)

```hcl
locals {
  aurora_clusters = {
    api_1 = {
      engine         = "aurora-postgresql"
      engine_version = "16.4"
      primary_class  = "db.r8g.16xlarge"
      reader_class   = "db.r8g.12xlarge"
      reader_count   = 2
      dr_class       = "db.r8g.16xlarge"
      storage_type   = "aurora-iopt1"
    }
    api_2 = {
      engine         = "aurora-postgresql"
      engine_version = "16.4"
      primary_class  = "db.r8g.xlarge"
      reader_class   = "db.r8g.xlarge"
      reader_count   = 1
      dr_class       = "db.r8g.xlarge"
      storage_type   = "aurora-iopt1"
    }
    api_3 = {
      engine         = "aurora-postgresql"
      engine_version = "16.4"
      primary_class  = "db.r8g.12xlarge"
      reader_class   = "db.r8g.8xlarge"
      reader_count   = 2
      dr_class       = "db.r8g.12xlarge"
      storage_type   = "aurora-iopt1"
    }
    api_4 = {
      engine         = "aurora-mysql"
      engine_version = "8.0.mysql_aurora.3.07.1"
      primary_class  = "db.r8g.4xlarge"
      reader_class   = "db.r8g.4xlarge"
      reader_count   = 1
      dr_class       = "db.r8g.4xlarge"
      storage_type   = "aurora-iopt1"
    }
  }

  valkey_clusters = {
    api_1 = { node_type = "cache.r7g.2xlarge", shards = 6, replicas_per_shard = 2 }
    api_2 = { node_type = "cache.r7g.large",   shards = 1, replicas_per_shard = 2 }
    api_3 = { node_type = "cache.r7g.2xlarge", shards = 4, replicas_per_shard = 2 }
    api_4 = { node_type = "cache.r7g.xlarge",  shards = 2, replicas_per_shard = 2 }
  }
}

```

