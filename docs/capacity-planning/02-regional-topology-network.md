## Sekcja 2: Topologia Regionalna, Sieć i Routing Globalny (Europa)

### 2.1. Wybór regionów AWS i suwerenność danych (GDPR)

Aby obsłużyć 134M MAU z Europy z najniższym opóźnieniem sieciowym i pełną zgodnością z RODO (dane nie opuszczają Europejskiego Obszaru Gospodarczego), wybieramy dwa największe i najbardziej dojrzałe regiony AWS w Europie:

1. **Region Główny (Primary): `eu-central-1` (Frankfurt)**
* Centralne położenie geograficzne w Europie (najniższe średnie RTT dla graczy z Niemiec, Polski, Francji, Włoch i krajów Beneluksu).
* Najwyższa dostępność wszystkich usług AWS (Aurora Global Database, ECS Fargate, Global Accelerator endpoints) oraz 3 fizycznie odseparowane Strefy Dostępności (`eu-central-1a`, `1b`, `1c`).


2. **Region Zapasowy (DR): `eu-west-1` (Irlandia)**
* Pełna parytetowość usług względem Frankfurtu, doskonałe połączenia transatlantyckie i zachodnioeuropejskie, bardzo niskie opóźnienie replikacji między regionami (~20–24 ms RTT między `eu-central-1` a `eu-west-1`).
* Gwarantuje przetrwanie całkowitej awarii regionu Frankfurt przy zachowaniu **RTO ≤ 15 min** i **RPO ≤ 5 min**.



---

### 2.2. Warstwa Edge i Inteligentny Routing Globalny

Przy **46,3k Peak RPS** pochodzących głównie z urządzeń mobilnych (Android), poleganie wyłącznie na rekordach DNS jest zbyt ryzykowne — operatorzy komórkowi agresywnie ignorują niskie wartości TTL, co wydłużyłoby przełączanie awaryjne (DR) poza nasze okno RTO 15 min.

Rozdzielamy ruch wejściowy na dwa wyspecjalizowane tory:

#### Tor A: Ruch API gier (API #1 – #4) -> AWS Global Accelerator + Route 53 ARC

* **AWS Global Accelerator (AGA):** udostępnia dwie statyczne pary adresów **Anycast IP** (osobne akceleratory lub osobne grupy listenerów per API dla pełnej izolacji *blast radius*). Ruch gracza wchodzi do sieci szkieletowej AWS na najbliższym punkcie brzegowym (Edge Location w Warszawie, Paryżu, Londynie, Frankfurcie) i płynie prywatną siecią AWS do `eu-central-1`.
* **Błyskawiczny Failover:** W przypadku awarii regionu Frankfurt, **Amazon Route 53 Application Recovery Controller (ARC)** (kontrola routingu oparta na płaszczyźnie danych, odporna na awarie płaszczyzny kontrolnej AWS) przestawia wagi ruchu w Global Acceleratorze na `0%` dla Frankfurtu i `100%` dla Irlandii. Zmiana propaguje się globalnie w **~30 sekund** bez jakiejkolwiek zmiany adresów IP po stronie klientów Android.
* **Ochrona przed DDoS:** Global Accelerator ma natywnie wbudowaną ochronę **AWS Shield Standard** na warstwach L3/L4, a na podpiętych pod nim Application Load Balancerach (ALB) uruchamiamy **AWS WAF** + **AWS Shield Advanced**.

#### Tor B: Aplikacja Web (*Dienekes Plaza Web*) -> Amazon CloudFront + WAF

* **Amazon CloudFront:** serwuje zasoby statyczne (JS, CSS, grafiki, WebAssembly) bezpośrednio z punktów Edge w całej Europie (odciążając kontenery ECS w 90%+), a ruch dynamiczny SSR/BFF kieruje do ALB w regionie głównym (z automatycznym *Origin Failover* na region DR `eu-west-1`).
* **AWS WAF (Web Application Firewall):** wpięty zarówno na CloudFront, jak i bezpośrednio na ALB obsługujące 4 API. Egzekwuje reguły *Rate-Based Rules* (ochrona przed zalaniem `/auth` i `/stats`), blokuje znane botnety oraz wymusza obecność wymaganych nagłówków autoryzacyjnych aplikacji mobilnych.

---

### 2.3. Architektura Sieciowa VPC i Plan Adresacji (IPAM)

Zamiast wrzucać wszystko do jednego gigantycznego VPC lub tworzyć dziesiątki małych sieci trudnych w utrzymaniu, stosujemy **architekturę domenową (2 VPC per region)** zarządzaną centralnie przez **Amazon VPC IP Address Manager (IPAM)**:

1. **VPC Core-Gaming (`10.10.0.0/16` w `eu-central-1`, `10.20.0.0/16` w `eu-west-1`):** obsługuje wysokowolumenowe *API #1* i *API #3* (95% ruchu).
2. **VPC Standard-Gaming (`10.11.0.0/16` w `eu-central-1`, `10.21.0.0/16` w `eu-west-1`):** obsługuje *API #2*, *API #4* oraz serwis *Dienekes Plaza Web*.

**Dlaczego `/16` (65 536 adresów IP) na każde VPC?**
Każde zadanie **ECS Fargate** (w trybie sieciowym `awsvpc`) otrzymuje własny, dedykowany adres IPv4 z podsieci prywatnej. Podczas nagłego skoku ruchu lub wdrożenia *Blue/Green* (podwojenie liczby kontenerów), brak wolnych adresów IP w podsieci jest jedną z najczęstszych ukrytych przyczyn awarii autoskalowania. Maska `/16` całkowicie eliminuje ten problem.

#### Podział na warstwy podsieci w każdym VPC (rozłożone równo na 3 AZ):

| Warstwa Podsieci | Maska na AZ (3x) | Dostępne IP / AZ | Rola i zasoby | Dostęp do Internetu |
| --- | --- | --- | --- | --- |
| **Public Subnets** | `/22` | 1 019 | Application Load Balancers (ALB), NAT Gateways (po 1 na AZ) | Bezpośredni przez Internet Gateway (IGW) |
| **Private App Subnets** | `/19` | 8 187 | Zadania **ECS Fargate** (4 API + Web), Amazon RDS Proxy | Wyłącznie wychodzący przez lokalny NAT Gateway w tej samej AZ |
| **Isolated Data Subnets** | `/22` | 1 019 | Klastry **Amazon Aurora**, **ElastiCache (Valkey/Redis)**, VPC Endpoints | **Brak dostępu** (ani przychodzącego, ani wychodzącego) |

---

### 2.4. Optymalizacja Ruchu Wewnętrznego i Ochrona przed Wąskimi Gardłami

Przy nieograniczonym budżecie naszym głównym wrogiem nie jest koszt transferu, lecz **limity przepustowości i pakiety na sekundę (PPS)** na urządzeniach sieciowych:

1. **AWS PrivateLink (Interface VPC Endpoints):** tworzymy prywatne endpointy wewnątrz VPC dla wszystkich usług AWS, z których korzystają kontenery (`ECR`, `Secrets Manager`, `CloudWatch Logs`, `SQS`, `Kinesis`, `DynamoDB`, `S3`, `KMS`). Dzięki temu żaden ruch wewnętrzny (np. pobieranie obrazów Dockera podczas autoskalowania czy wysyłanie 41k zdarzeń/s do SQS/Kinesis) nie przechodzi przez NAT Gatewaye.
2. **Dedykowane NAT Gateways na każdą AZ (3x per VPC):** służą wyłącznie do komunikacji wychodzącej z zewnętrznymi dostawcami (weryfikacja paragonów Google Play Billing, bramki płatności Web, zewnętrzni dostawcy OAuth). Przypisujemy im elastyczne pule adresów IP (do 8 Elastic IP na NAT Gateway), aby uniknąć wyczerpania portów źródłowych (**SNAT Port Exhaustion**) przy gwałtownych skokach zapytań do Google API.
3. **Cross-Zone Load Balancing i NLB/ALB:** przed klastrami ECS stawiamy osobne **Application Load Balancers** dla każdego API (4 ALB + 1 ALB dla Web), wstępnie rozgrzane (*ALB Pre-Warming* zgłoszone przez AWS Support przed premierą/migracją), aby bez opóźnień przyjęły skok do 46,3k RPS.

---

### 2.5. Krytyczne Limity AWS (*Service Quotas*) do podniesienia przed startem

Domyślne limity świeżego konta AWS zatrzymałyby ten system w kilka minut. W ramach kodu Terraform (`aws_servicequotas_service_quota`) podnosimy na starcie:

* **Fargate On-Demand vCPU count:** z domyślnych 100–500 na **10 000 vCPU** na region.
* **VPC Elastic IP addresses:** z 5 na **50** na region.
* **ALB Target Groups per Load Balancer:** z 100 na **200**.
* **NAT Gateway active connections:** monitorowanie metryki `ErrorPortAllocation` + konfiguracja wielu adresów IP na NAT Gateway.

---

### 2.6. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 2)

```hcl
locals {
  regions = {
    primary = "eu-central-1" # Frankfurt
    dr      = "eu-west-1"    # Ireland
  }

  vpc_topology = {
    primary = {
      core_gaming     = { cidr = "10.10.0.0/16", azs = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
      standard_gaming = { cidr = "10.11.0.0/16", azs = ["eu-central-1a", "eu-central-1b", "eu-central-1c"] }
    }
    dr = {
      core_gaming     = { cidr = "10.20.0.0/16", azs = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
      standard_gaming = { cidr = "10.21.0.0/16", azs = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
    }
  }

  vpc_endpoints_interface = [
    "ecr.api", "ecr.dkr", "logs", "secretsmanager",
    "sqs", "kinesis-streams", "kms", "monitoring"
  ]
  vpc_endpoints_gateway = ["s3", "dynamodb"]
}

```
