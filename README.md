# Resilient AWS Gaming Infrastructure (IaC)

Kompletna infrastruktura jako kod (**OpenTofu / Terraform**) dla wieloregionowego ekosystemu **6 gier** (5 tytułów mobilnych Android oraz 1 wersja Web) na platformie AWS w Europie.

System został zaprojektowany dla skali **134M MAU** i szczytowego obciążenia **46 313 Peak RPS** (*Sizing Envelope*), gwarantując dostępność **SLI ≥ 99,5%**, **RPO ≤ 5 minut** oraz **RTO ≤ 15 minut** przy pełnej zgodności z RODO (GDPR).

---

## 1. Kluczowe Parametry i Cele Operacyjne (SLA / SLO)

| Parametr | Wartość docelowa | Realna wydajność architektury |
| :--- | :--- | :--- |
| **Skala użytkowników** | 134,0M MAU / 11,6M DAU | ~96k–103k jednoczesnych graczy (CCU) |
| **Szczytowy ruch (Peak RPS)** | 43 215 RPS (wzór) | **46 313 RPS** (*Sizing Envelope*) |
| **Zewnętrzne SLI (Dostępność)** | **≥ 99,5%** (maks. 216 min/mies.) | Wewnętrzne SLO: `/payments` **99,99%**, `/auth` **99,95%**, `/stats` **99,90%** |
| **Recovery Point Objective (RPO)** | **≤ 5 minut** | **< 5 sekund** (Aurora Global DB + DynamoDB Global Tables + SQS) |
| **Recovery Time Objective (RTO)** | **≤ 15 minut** | **~6 minut 30 sekund** (Warm Standby + Route 53 ARC) |
| **Regiony AWS (GDPR)** | Wyłącznie EOG | Primary: **`eu-central-1`** (Frankfurt) \| DR: **`eu-west-1`** (Irlandia) |

---

## 2. Przegląd Architektury i Obsługiwanych Gier

Architektura opiera się na sprawdzonych usługach zarządzanych AWS (*boring technology*) z rygorystyczną izolacją *blast radius* per gra oraz per ścieżka biznesowa (`/stats` 89%, `/auth` 9,4%, `/payments` 1,6%):

* **Edge & Routing Globalny:** **AWS Global Accelerator** (Anycast IP) sterowany przez **Route 53 ARC** (przełączenie regionu w ~30 s bez zależności od TTL DNS) oraz **Amazon CloudFront + AWS WAF** dla *Dienekes Plaza Web*.
* **Warstwa Obliczeniowa:** **Amazon ECS na AWS Fargate (ARM64 / Graviton)** podzielony na 5 klastrów i **13 odizolowanych serwisów** (osobne pule zasobów i autoskalowanie dla `/stats`, `/auth`, `/payments` oraz `web`).
* **Warstwa Danych i Cache:**
  * **API #1** (*Pythodorus 3* — 75M MAU): **Aurora PostgreSQL** (`db.r8g.16xlarge`) + **ElastiCache Valkey** (6 shardów).
  * **API #2** (*Theognis per Megara* — 1M MAU): **Aurora PostgreSQL** (`db.r8g.xlarge`) + **ElastiCache Valkey** (1 shard).
  * **API #3** (*Agrippa Mosa* + *Agrippa Mosa 2* — 52M MAU): **Aurora PostgreSQL** (`db.r8g.12xlarge`) + **ElastiCache Valkey** (4 shardy).
  * **API #4** (*Dienekes Plaza* Android + Web — 6M MAU): **Aurora MySQL** (`db.r8g.4xlarge`) + **ElastiCache Valkey** (2 shardy).
  * Wszystkie klastry chronione przez **Amazon RDS Proxy** (Endpointy RW/RO) oraz wspierane przez **DynamoDB Global Tables** (sesje `/auth`) i **Amazon SQS** (buforowanie *Write-Behind* dla `/stats`).

---

## 3. Struktura Repozytorium

```text
.
├── docs/                              # Single Source of Truth (Architektura, Wyliczenia, Governance)
│   ├── requirements/
│   │   └── nfr-baseline.md            # Surowe wymagania biznesowe, metryki gier i cele SLA/DR
│   ├── capacity-planning/
│   │   └── sizing-model.md            # Matematyka ruchu (Sekcje 1–12), dobór instancji i budżet RTO
│   ├── hld/
│   │   └── architecture.md            # High-Level Design, diagramy przepływów i model Warm Standby
│   ├── lld/
│   │   └── module-contracts.md        # Kontrakty wejść/wyjść modułów oraz podział warstw stanu
│   ├── governance/
│   │   ├── cidr-plan.md               # Plan adresacji IPAM (/16 per VPC) dla wszystkich kont AWS
│   │   └── tagging-policy.md          # Obowiązkowe tagi i konwencja nazewnictwa zasobów
│   └── adr/
│       └── ADR-001.md ... ADR-011.md  # Rejestr Decyzji Architektonicznych (Architecture Decision Records)
├── modules/                           # Reużywalne moduły OpenTofu / Terraform
│   ├── network-vpc/                   # VPC /16, 3 AZ, podsieci, NAT Gateways, VPC PrivateLink Endpoints
│   ├── edge-routing/                  # Global Accelerator, Route 53 ARC, CloudFront, AWS WAF
│   ├── data-aurora-global/            # Aurora Global Database (PG/MySQL), I/O-Optimized, RDS Proxy
│   ├── data-valkey-dynamodb/          # ElastiCache Valkey (Cluster Mode), DynamoDB Global Tables, SQS
│   ├── compute-ecs-fargate/           # Klastry ECS, Fargate ARM64, ALB Path Routing, CodeDeploy Canary
│   └── observability-security/        # Multi-Region KMS, IAM, AMP/AMG, alarmy SLO Burn Rate, AWS FIS
├── environments/                      # Konfiguracje środowisk z izolowanymi plikami stanu
│   ├── shared-services/               # ECR, CI/CD, Managed Grafana
│   ├── dev/                           # Środowisko deweloperskie i Ephemeral PRs (skala 5%)
│   ├── staging/                       # Bramka przedprodukcyjna z aktywnym DR (skala 15%)
│   ├── perf-opt/                      # Wierna kopia produkcji w skali 1:1 do testów obciążeniowych i DR
│   └── prod/                          # Środowisko produkcyjne (Frankfurt + Irlandia)
├── scripts/                           # Narzędzia pomocnicze (generator 134M syntetycznych kont, testy DR)
├── Makefile                           # Automatyzacja formatowania, walidacji i skanowania bezpieczeństwa
└── README.md                          # Ten plik