# High-Level Design (HLD): Resilient AWS Gaming Infrastructure

## 1. Cel i Wymagania Niefunkcjonalne
System obsługuje ekosystem 6 gier (5 mobilnych Android + 1 Web) o łącznej skali **134M MAU** i szczytowym obciążeniu **46 313 Peak RPS** (*Sizing Envelope*).

* **Dostępność (SLI):** ≥ 99,5% (wewnętrzne SLO: `/payments` 99,99%, `/auth` 99,95%, `/stats` 99,90%).
* **Recovery Point Objective (RPO):** ≤ 5 minut (realnie < 5 sekund).
* **Recovery Time Objective (RTO):** ≤ 15 minut (realnie ~6,5 minuty).
* **Lokalizacja i Compliance:** Wyłącznie Europejski Obszar Gospodarczy (`eu-central-1` Frankfurt + `eu-west-1` Irlandia), pełna zgodność z RODO (GDPR).

---

## 2. Diagram Architektury Logicznej (Region Główny: `eu-central-1`)

```text
                       [ Gracze Android (5 gier) ]             [ Gracze Web (Dienekes) ]
                                    |                                      |
                        (Anycast IP / TLS 1.3)                     (HTTPS / TLS 1.3)
                                    v                                      v
                    +-------------------------------+      +-------------------------------+
                    |    AWS Global Accelerator     |      |   Amazon CloudFront + WAF     |
                    |   (sterowany Route 53 ARC)    |      |   (S3 Assets + Origin ALB)    |
                    +-------------------------------+      +-------------------------------+
                                    |                                      |
          +-------------------------+-------------------------+            |
          v                         v                         v            v
  +---------------+         +---------------+         +---------------+  +---------------+
  |  ALB: API #1  |         |  ALB: API #2  |         |  ALB: API #3  |  | ALB: API #4+W |
  | (Pythodorus 3)|         |  (Theognis)   |         | (Agrippa 1+2) |  | (Dienekes)    |
  +---------------+         +---------------+         +---------------+  +---------------+
          |                         |                         |                  |
          +-------------------------+-------------------------+------------------+
                                    | (Path-Based Routing: /stats, /auth, /payments)
                                    v
  +--------------------------------------------------------------------------------------+
  |                     WARSTWA OBLICZENIOWA: Amazon ECS Fargate (ARM64)                 |
  |                                                                                      |
  |  +------------------------+   +------------------------+   +----------------------+  |
  |  |  service-stats (89%)   |   |  service-auth (9,4%)   |   | service-payments(1,6%)|  |
  |  |  p99 < 150ms           |   |  p99 < 100ms           |   | p99 < 400ms (ACID)   |  |
  |  +------------------------+   +------------------------+   +----------------------+  |
  +--------------------------------------------------------------------------------------+
               |              |                |                          |
      (Read/Write)      (Async Buffer)   (Refresh Tokens)          (Sync Write)
               v              v                v                          v
  +-------------------+ +-----------+ +--------------------+   +----------------------+
  | ElastiCache       | | Amazon    | | Amazon DynamoDB    |   | Amazon RDS Proxy     |
  | Valkey (Cluster)  | | SQS       | | Global Tables      |   | (RW & RO Endpoints)  |
  +-------------------+ +-----------+ +--------------------+   +----------------------+
                              |                                           |
                              +-----> [ ecs-worker-stats ] -------------->+
                                        (Batch Upsert 2s)                 v
                                                               +----------------------+
                                                               | Aurora Global DB     |
                                                               | PG 16 (API 1-3)      |
                                                               | MySQL 8.0 (API 4)    |
                                                               +----------------------+
                                                                          |
                                                           (Storage Replication < 1s)
                                                                          v
                                                               [ Region DR: eu-west-1 ]