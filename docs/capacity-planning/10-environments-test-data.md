## Sekcja 10: Strategia Środowisk (Dev, Staging, Perf/Opt 1:1) i Zarządzanie Danymi Testowymi

### 10.1. Izolacja na Poziomie Kont AWS (*AWS Organizations & Control Tower*)

Trzymanie środowisk testowych i produkcyjnych na jednym koncie AWS (nawet w osobnych VPC) to przy tej skali **krytyczny antywzorzec**. Test wydajnościowy na 46k RPS na tym samym koncie zużyłby limity współbieżnych zadań Fargate, przepustowość API AWS oraz pule adresów Elastic IP, blokując autoskalowanie produkcji.

Tworzymy ustrukturyzowaną hierarchię w **AWS Organizations** z centralnym logowaniem przez **AWS IAM Identity Center (SSO)**:

1. **`gaming-shared-services` (Konto platformowe):** centralny rejestr obrazów **Amazon ECR**, potoki CI/CD, artefakty Terraform, prywatne moduły oraz **Amazon Managed Grafana**.
2. **`gaming-security-audit` (Konto audytowe):** niemodyfikowalne logi **CloudTrail**, archiwa zgodności S3 Object Lock (RODO) i centralny AWS Security Hub (brak dostępu zapisu dla deweloperów).
3. **`gaming-dev` (Konto deweloperskie):** współdzielone środowisko integracyjne dla programistów gier oraz automatyczne środowiska tymczasowe (*Ephemeral PR Environments*).
4. **`gaming-staging` (Konto przedprodukcyjne):** bramka jakościowa (*Release Gate*) przed każdym wdrożeniem na produkcję.
5. **`gaming-perf-opt` (Konto optymalizacji i Chaos Engineeringu):** pełnowymiarowe środowisko **1:1 względem produkcji** (włącznie z regionem DR `eu-west-1`).
6. **`gaming-load-gen` (Konto generatorów ruchu):** odizolowane konto, z którego uruchamiamy rozproszone generatory obciążenia (k6 / Locust), aby ruch testowy przechodził przez publiczny Internet, Global Accelerator, CloudFront i WAF dokładnie tak jak ruch prawdziwych graczy.
7. **`gaming-prod` (Konto produkcyjne):** dostęp wyłącznie przez zautomatyzowane potoki CI/CD oraz procedury awaryjne *Break-Glass* dla dyżurnych SRE.

---

### 10.2. Porównanie Konfiguracji Środowisk

Wszystkie środowiska budujemy z **tych samych modułów Terraform** — różnią się wyłącznie przekazanymi zmiennymi wymiarowania (`tfvars`), co eliminuje błędy typu „na stagingu działało, na produkcji padło przez inną konfigurację RDS Proxy”.

| Parametr | Dev / Ephemeral (PR) | Staging (Pre-Prod) | Perf / Opt (1:1) | Produkcja (Prod) |
| --- | --- | --- | --- | --- |
| **Regiony AWS** | Tylko `eu-central-1` (Single-Region) | `eu-central-1` + `eu-west-1` (DR aktywny) | `eu-central-1` + `eu-west-1` (DR 1:1) | `eu-central-1` + `eu-west-1` (DR 1:1) |
| **Skala mocy ECS** | Minimalna (po 1 zadaniu `0.5 vCPU / 1 GB`) | ~15% mocy szczytowej (po 2 zadania/AZ) | **100% (identyczna jak Prod: 93–273 zadań)** | **100% (93–273 zadań)** |
| **Baza danych** | Aurora Serverless v2 (`0.5–4 ACU`, brak replik) | Małe instancje `db.r8g.large` + 1 replika | **Identyczne klasy `db.r8g.16xlarge` itd.** | **Pełne klasy `db.r8g.16xlarge` itd.** |
| **ElastiCache (Valkey)** | 1 mały węzeł `cache.r7g.large` (bez klastrów) | 1 shard + 1 replika (Cluster Mode) | **Identyczna topologia (do 6 shardów)** | **Pełna topologia (do 6 shardów)** |
| **Płatności (3rd-Party)** | Lokalne mocki / symulatory | Google Play Sandbox / Stripe Test Mode | Symulator opóźnień (WireMock / FIS) | Prawdziwe Google Play / Bramki Web |
| **Czas życia** | PR: niszczone po merge; Dev: 24/7 | Stałe (24/7) | Uruchamiane na żądanie / harmonogram testów | Stałe (24/7) |

---

### 10.3. Środowisko Perf / Opt (1:1) — Fabryka Wydajności i Testów DR

Przy nieograniczonym budżecie **Perf / Opt** jest naszą najważniejszą polisą ubezpieczeniową gwarantującą **SLI ≥ 99,5%**, **RPO ≤ 5 min** i **RTO ≤ 15 min**:

1. **Testy obciążeniowe na pełną skalę (50k+ RPS):**
* Z konta `gaming-load-gen` (rozłożonego na kilka regionów europejskich, np. Paryż, Londyn, Sztokholm) uruchamiamy klaster kontenerów Fargate z **k6 / Locust**, który odtwarza dokładny profil ruchu: **89% `/stats**`, **9,4% `/auth**`, **1,6% `/payments**` na poziomie **46 313 RPS** (a w testach wytrzymałościowych *Stress Test* do **70 000 RPS**, czyli 150% szczytu).
* Każdy większy release kodu API, zmiana wersji silnika Aurora lub modyfikacja indeksów SQL musi przejść 2-godzinny test obciążeniowy w **Perf/Opt** bez przekroczenia budżetu opóźnień p99.


2. **Automatyczne włączanie i parkowanie (FinOps / Higiena):**
* Mimo nieograniczonego budżetu, automatyczny potok CI/CD podnosi środowisko `Perf/Opt` na czas okien testowych (np. 3 razy w tygodniu lub przed każdym wydaniem gry) i usypia nadmiarowe instancje poza oknami testów, utrzymując czysty stan infrastruktury bez dryfu konfiguracyjnego (*Configuration Drift*).



---

### 10.4. Zarządzanie Danymi Testowymi (GDPR & Zasilanie 75M+ Kont)

**Bezwzględna zasada bezpieczeństwa i RODO:** Nigdy nie wykonujemy zrzutów (`pg_dump` / `mysqldump` / snapshotów) produkcyjnych baz danych na środowiska Dev, Staging ani Perf/Opt — nawet po anonimizacji (ryzyko wycieku kluczy szyfrujących, tokenów płatności lub błędów w skryptach maskujących).

1. **Generator Danych Syntetycznych (Data Seeding Pipeline):**
* Przygotowujemy dedykowany skrypt/narzędzie (uruchamiane jako jednorazowe zadanie AWS Batch / ECS Task), które wypełnia bazy w **Perf/Opt** realistycznym rozkładem danych o produkcyjnej objętości:
* **75 milionów** syntetycznych profili graczy dla `aurora-api-1` (*Pythodorus 3*),
* **52 miliony** profili dla `aurora-api-3` (*Agrippa Mosa* + *Mosa 2*),
* **6 milionów** profili dla `aurora-api-4` (*Dienekes Plaza* Android + Web),
* **1 milion** profili dla `aurora-api-2` (*Theognis per Megara*).


* Pozwala to testować prawdziwą wydajność zapytań SQL, rozmiar indeksów B-Tree, działanie partycjonowania `pg_partman` oraz czas promowania bazy podczas failoveru na wieloterabajtowych wolumenach danych.


2. **Deterministyczne konta testowe:**
* W każdym środowisku nieprodukcyjnym wgrywany jest stały zestaw **10 000 deterministycznych kont testowych** (o znanych identyfikatorach i predefiniowanym stanie ekwipunku), z których korzystają automatyczne testy E2E w potokach CI/CD oraz testerzy QA gier mobilnych.



---

### 10.5. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 10)

```hcl
locals {
  aws_accounts = {
    shared_services = { email_alias = "aws-shared",   purpose = "ECR, CI/CD, Grafana" }
    security_audit  = { email_alias = "aws-audit",    purpose = "CloudTrail, S3 Object Lock" }
    dev             = { email_alias = "aws-dev",      purpose = "Dev & Ephemeral PR envs" }
    staging         = { email_alias = "aws-staging",  purpose = "Pre-prod release gate" }
    perf_opt        = { email_alias = "aws-perf",     purpose = "1:1 Scale Load & Chaos Testing" }
    load_gen        = { email_alias = "aws-loadgen",  purpose = "Distributed k6/Locust generators" }
    prod            = { email_alias = "aws-prod",     purpose = "Production EU (Frankfurt + Ireland)" }
  }

  env_scaling_profiles = {
    dev      = { scale_factor = 0.05, multi_region = false, db_mode = "serverless-v2" }
    staging  = { scale_factor = 0.15, multi_region = true,  db_mode = "provisioned-small" }
    perf_opt = { scale_factor = 1.00, multi_region = true,  db_mode = "provisioned-prod-parity" }
    prod     = { scale_factor = 1.00, multi_region = true,  db_mode = "provisioned-prod-parity" }
  }

  synthetic_seed_volumes = {
    api_1 = 75000000
    api_2 = 1000000
    api_3 = 52000000
    api_4 = 6000000
  }
}

```
