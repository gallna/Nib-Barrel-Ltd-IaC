# Cloud Governance: Plan Adresacji Sieciowej (CIDR Plan)

## 1. Zasady Ogólne
* Wszystkimi przestrzeniami adresowymi zarządza **Amazon VPC IPAM** w ramach prywatnej puli RFC 1918 (`10.0.0.0/8`).
* **Zero nakładania się adresów (Non-Overlapping CIDRs):** Każde konto AWS, środowisko i region posiadają unikalny blok `/16`, co umożliwia bezpieczne zestawienie **AWS Transit Gateway** lub VPC Peeringu w przyszłości bez konfliktów routingu.
* **Ochrona przed wyczerpaniem IP:** Każde VPC otrzymuje maskę `/16` (65 536 adresów IP), aby zapewnić zapas adresów dla zadań ECS Fargate (`awsvpc`) podczas nagłego autoskalowania i wdrożeń Canary.

---

## 2. Alokacja Bloków VPC per Konto i Region

| Konto AWS (Środowisko) | Domena VPC | Region | Blok CIDR VPC | Strefy Dostępności (AZ) |
| :--- | :--- | :--- | :---: | :--- |
| **`gaming-prod`** | `core-gaming` (API #1, #3) | `eu-central-1` | `10.10.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-prod`** | `standard-gaming` (API #2, #4, Web) | `eu-central-1` | `10.11.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-prod`** | `core-gaming-dr` (API #1, #3) | `eu-west-1` | `10.20.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-prod`** | `standard-gaming-dr` (API #2, #4, Web) | `eu-west-1` | `10.21.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-perf-opt`** | `core-gaming` (Skala 1:1) | `eu-central-1` | `10.30.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-perf-opt`** | `standard-gaming` (Skala 1:1) | `eu-central-1` | `10.31.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-perf-opt`** | `core-gaming-dr` (Skala 1:1) | `eu-west-1` | `10.40.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-perf-opt`** | `standard-gaming-dr` (Skala 1:1) | `eu-west-1` | `10.41.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-staging`** | `staging-primary` (Wspólne VPC) | `eu-central-1` | `10.50.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-staging`** | `staging-dr` (Wspólne VPC) | `eu-west-1` | `10.51.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-dev`** | `dev-shared` (Single-Region) | `eu-central-1` | `10.60.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-shared-services`** | `shared-tooling` | `eu-central-1` | `10.70.0.0/16` | `1a`, `1b`, `1c` |
| **`gaming-load-gen`** | `load-generators` | `eu-west-3` (Paryż) | `10.80.0.0/16` | `3a`, `3b`, `3c` |
| *Rezerwa przyszła* | *Future Expansion* | *EU Regions* | `10.100.0.0/14` | — |

---

## 3. Wewnętrzny Podział Podsieci (Szablon dla każdego VPC `/16`)

Każde VPC dzielimy identycznie na **9 podsieci** (3 warstwy × 3 Strefy Dostępności), pozostawiając górną połowę bloku (`/17`) jako rezerwę na przyszłe dedykowane podsieci (np. EKS lub Redshift):

| Warstwa Podsieci | AZ-1 (offset) | AZ-2 (offset) | AZ-3 (offset) | Maska | Użyteczne IP / AZ | Przeznaczenie |
| :--- | :---: | :---: | :---: | :---: | ---: | :--- |
| **Public Subnets** | `.0.0/22` | `.4.0/22` | `.8.0/22` | `/22` | 1 019 | ALB, NAT Gateways (1 per AZ) |
| **Isolated Data Subnets** | `.16.0/22` | `.20.0/22` | `.24.0/22` | `/22` | 1 019 | Aurora DB, ElastiCache Valkey, VPC Endpoints |
| **Private App Subnets** | `.32.0/19` | `.64.0/19` | `.96.0/19` | `/19` | 8 187 | Zadania ECS Fargate, Amazon RDS Proxy |
| *Rezerwa wewnątrz VPC* | `.128.0/17` | — | — | `/17` | 32 766 | Rezerwa na rozbudowę |

*(Przykład dla `10.10.0.0/16`: Public = `10.10.0.0/22`, `10.10.4.0/22`, `10.10.8.0/22`; Data = `10.10.16.0/22`, `10.10.20.0/22`, `10.10.24.0/22`; Private App = `10.10.32.0/19`, `10.10.64.0/19`, `10.10.96.0/19`).*