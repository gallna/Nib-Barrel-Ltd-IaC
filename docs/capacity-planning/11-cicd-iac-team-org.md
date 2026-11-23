## Sekcja 11: CI/CD, Infrastructure as Code i Organizacja Zespołów

### 11.1. Architektura Infrastructure as Code (OpenTofu / Terraform)

Przy 44 inżynierach pracujących równolegle nad 4 API, aplikacją Web i dwoma regionami AWS, trzymanie całej infrastruktury w jednym pliku stanu Terraform (`terraform.tfstate`) spowodowałoby ciągłe blokady (`State Lock`) i ryzyko przypadkowego nadpisania bazy produkcyjnej przy zmianie reguły WAF.

Stosujemy **architekturę warstwową z izolacją stanów (Layered State Architecture)**:

#### Podział repozytorium (`infra-gaming-aws/`):

1. **`00-foundation/` (Zmiany rzadkie — kwartalne):** AWS Organizations, SCP (blokada regionów poza UE), konta, IAM Identity Center, klucze Multi-Region KMS oraz IPAM.
2. **`01-network-edge/` (Zmiany miesięczne):** VPC (`core_gaming`, `standard_gaming`), podsieci, NAT Gateways, VPC Endpoints, Global Accelerator, Route 53 ARC, CloudFront i reguły WAF.
3. **`02-data-stateful/` (Zmiany ostrożne — wysoka ochrona):** Klastry Aurora Global Database, RDS Proxy, ElastiCache (Valkey), DynamoDB Global Tables oraz kolejki SQS. Posiada osobny stan dla każdego API (`api-1`..`api-4`), aby aktualizacja bazy *Theognis per Megara* nie blokowała prac nad *Pythodorus 3*.
4. **`03-compute-apps/` (Zmiany codzienne — CI/CD):** Klastry ECS, serwisy Fargate (`/stats`, `/auth`, `/payments`, `web`), reguły ALB, polityki autoskalowania oraz definicje alarmów SLO.

**Zasady higieny IaC:**

* **Uwierzytelnianie bez kluczy (OIDC):** Potoki GitHub Actions / GitLab CI łączą się z AWS wyłącznie przez **OpenID Connect (OIDC)** — zero długotrwałych kluczy `AWS_ACCESS_KEY_ID`.
* **Automatyczne bramki bezpieczeństwa (*Policy-as-Code*):** Każdy Pull Request w repozytorium IaC musi przejść automatycznie: `tofu fmt -check`, `tofu validate`, `tflint` oraz skanowanie bezpieczeństwa **Checkov / Trivy** (blokada wdrożenia zasobów bez szyfrowania KMS lub z otwartymi Security Groups).
* **Detekcja dryfu (*Drift Detection*):** Nocne zadanie CI uruchamia `tofu plan -detailed-exitcode` na wszystkich warstwach produkcyjnych i wysyła alert na Slacka SRE, jeśli ktoś dokonał ręcznej zmiany w konsoli AWS.

---

### 11.2. Potoki CI/CD Aplikacji i Wdrożenia Canary (Zero-Downtime)

Wdrożenie nowego kodu nie może naruszyć naszego **SLI ≥ 99,5%**. Stosujemy pełną automatyzację budowania i progresywnego wydawania:

1. **Budowanie i utwardzanie obrazów (CI):**
* Budowa wieloarchitekturowych obrazów kontenerów (**ARM64 / Graviton**) opartych o minimalne obrazy bazowe (`distroless` lub `alpine` bez powłoki bash/curl w wersji produkcyjnej).
* Skanowanie podatności CVE w **Amazon ECR (Inspector)** oraz podpisywanie kryptograficzne obrazów narzędziem **AWS Signer / Cosign** (ECS odrzuca niepodpisane obrazy).


2. **Strategia Wdrożeń Progresywnych (Canary Deployment na ECS):**
* Wdrożenia na `Staging` i `Prod` realizujemy przez **AWS CodeDeploy dla Amazon ECS** w trybie **`CodeDeployDefault.ECSCanary10Percent5Minutes`**:
* **Krok 1:** Nowa wersja zadania uruchamia się na **10% ruchu** produkcyjnego przez **5 minut**.
* **Krok 2 (Automatyczna bramka SRE):** CodeDeploy w czasie rzeczywistym monitoruje alarmy CloudWatch powiązane z naszymi SLO (odsetek błędów `HTTP 5xx`, opóźnienie `p99` na ALB, błędy zapisu SQS/RDS). Jeśli którykolwiek wskaźnik przekroczy próg, CodeDeploy w ciągu **15 sekund automatycznie cofa ruch** na starą wersję i ubija wadliwe kontenery bez udziału człowieka.
* **Krok 3:** Jeśli 5-minutowe okno kanarkowe przejdzie czysto, ruch jest płynnie przełączany na **100%** nowej wersji.




3. **Bezpieczne migracje schematów baz danych (*Expand and Contract*):**
* Zakaz bezpośrednich zmian niszczących w SQL (np. `DROP COLUMN`, `RENAME TABLE`, zakładanie indeksów bez `CONCURRENTLY` w PostgreSQL).
* Migracje (zarządzane przez **Flyway / Liquibase**) wykonywane są jako osobny krok przed wdrożeniem kontenerów wyłącznie w modelu wstecznie kompatybilnym (*Expand* -> wdrożenie nowego kodu -> *Contract* w kolejnym wydaniu).



---

### 11.3. Organizacja Zespołów (22 Senior DevOps + 22 Senior SRE)

Posiadanie 44 seniorów to ogromna siła robocza, ale bez jasnego podziału granic odpowiedzialności szybko doprowadzi do chaosu i powielania pracy. Organizujemy ich w **6 wyspecjalizowanych zespołów (po 7–8 osób)** według sprawdzonych wzorców *Team Topologies*:

| Zespół | Skład | Odpowiedzialność i domena |
| --- | --- | --- |
| **1. Core Platform & Edge Team** | 6 DevOps + 2 SRE | Konta AWS Organizations, sieci VPC, Global Accelerator, CloudFront, WAF, IPAM, wspólne moduły bazowe Terraform. |
| **2. Data & Storage Reliability Team** | 4 DevOps + 4 SRE | Klastry Aurora Global Database (PG i MySQL), RDS Proxy, Valkey, DynamoDB, partycjonowanie danych, testy RPO/RTO i backupy. |
| **3. CI/CD & Developer Experience Team** | 6 DevOps + 1 SRE | Potoki budowania, rejestr ECR, środowiska Ephemeral PR, środowisko Perf/Opt 1:1, generatory danych syntetycznych. |
| **4. Observability & Chaos Engineering Team** | 2 DevOps + 5 SRE | Stos OpenTelemetry, Managed Prometheus/Grafana, konfiguracja alertów SLO Burn Rate, testy Chaos Engineering (AWS FIS) i organizacja *GameDays*. |
| **5. Stream-Aligned Squad: Core Hits (API #1 & #3)** | 2 DevOps + 5 SRE | Bezpośrednie wsparcie dla *Pythodorus 3* (75M MAU) oraz *Agrippa Mosa 1/2* (52M MAU) — 95% ruchu ekosystemu; strojenie `/stats` i wdrożenia Canary. |
| **6. Stream-Aligned Squad: Growth & Web (API #2, #4 & Web)** | 2 DevOps + 5 SRE | Bezpośrednie wsparcie dla *Theognis per Megara*, *Dienekes Plaza* (Android + Web) oraz warstwy BFF/SSR. |

#### Model Dyżurów (*On-Call Rotation*):

* Dzięki 22 Senior SRE tworzymy **dwie niezależne rotacje 24/7** (*Primary On-Call* + *Secondary Escalation* dla strefy czasowej CET/EET):
* **Rotacja A (Infrastructure & Data SRE):** odpowiada za sieć, bazy Aurora, Valkey i procedury DR Multi-Region.
* **Rotacja B (Application & Edge SRE):** odpowiada za serwisy ECS, wdrożenia Canary, integracje 3rd-party i WAF.


* Każdy inżynier pełni dyżur raz na **5–6 tygodni**, co całkowicie eliminuje wypalenie zawodowe i daje czas na pracę projektową nad automatyzacją.

---

### 11.4. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 11)

```hcl
locals {
  iac_state_layers = [
    "00-foundation",
    "01-network-edge",
    "02-data-stateful-api1",
    "02-data-stateful-api2",
    "02-data-stateful-api3",
    "02-data-stateful-api4",
    "03-compute-apps"
  ]

  codedeploy_ecs_config = {
    deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"
    auto_rollback_enabled  = true
    auto_rollback_events   = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
    termination_wait_time  = 5 # minuty na ewentualne natychmiastowe cofnięcie bez ponownego startu kontenerów
  }
}

```