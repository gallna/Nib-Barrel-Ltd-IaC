# Capacity & Sizing Model

## Sekcja 1: Założenia Architektoniczne i Capacity Planning

### 1.1. Model matematyczny i weryfikacja metryk użytkowników

Do przeliczenia ruchu przyjmujemy następujące stałe operacyjne:

* **Dzienny czas gry ($T_{\text{play}}$):** $12\text{ min} = 720\text{ s}$ (z $86\,400\text{ s}$ w dobie).
* **Średnia liczba jednoczesnych graczy ($\text{Avg CCU}$):**

$$\text{Avg CCU} = \frac{\text{DAU} \times 720}{86\,400} = \frac{\text{DAU}}{120}$$


* **Szczytowy ruch ($\text{Peak RPS}$):**

$$\text{Peak RPS} = \text{Avg CCU} \times 0,15\text{ req/s} \times 3,0 = \text{Avg CCU} \times 0,45$$



**Ważna obserwacja inżynieryjna (rozbieżność DAU vs MAU):**
Porównanie deklarowanego DAU z wartością wyliczoną ze wzoru ($\text{MAU} \times 8,6\%$) pokazuje dwie grupy gier:

1. **Dojrzałe hity masowe** (*Pythodorus 3*, *Agrippa Mosa*) mają stickiness na poziomie ~8,0%, więc formuła z MAU (8,6%) daje lekki zapas bezpieczeństwa.
2. **Nowsze lub niszowe tytuły** (*Theognis per Megara*, *Agrippa Mosa 2*, *Dienekes Plaza*) mają realne stickiness na poziomie **15–20%**.

**Decyzja architektoniczna:** W tabeli poniżej prezentujemy dokładny wynik ze wzoru (dla zgodności z założeniami), ale infrastrukturę wymiarujemy pod **Sizing Envelope** ($\max(\text{DAU}_{\text{wzór}}, \text{DAU}_{\text{deklarowane}})$), aby nie zdławić mniejszych gier w godzinach szczytu.

| Gra | Platforma | API | MAU | DAU (deklar.) | DAU (8,6% MAU) | Avg CCU (wzór) | Peak RPS (wzór) | Peak RPS (Sizing Envelope) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Pythodorus 3** | Android | API #1 | 75,0M | 6,00M | 6,45M | 53 750 | **24 187,5** | **24 188** |
| **Theognis per Megara** | Android | API #2 | 1,0M | 0,20M | 0,086M | 717 | **322,5** | **750** |
| **Agrippa Mosa** | Android | API #3 | 50,0M | 4,00M | 4,30M | 35 833 | **16 125,0** | **16 125** |
| **Agrippa Mosa 2** | Android | API #3 | 2,0M | 0,30M | 0,172M | 1 433 | **645,0** | **1 125** |
| **Dienekes Plaza** | Android | API #4 | 5,0M | 1,00M | 0,43M | 3 583 | **1 612,5** | **3 750** |
| **Dienekes Plaza Web** | Web | API #4 | 1,0M | 0,10M | 0,086M | 717 | **322,5** | **375** |
| **SUMA EKOSYSTEMU** | — | **4 API** | **134,0M** | **11,60M** | **11,524M** | **96 033** | **43 215,0** | **46 313** |

*(Uwaga dla usługi Web: dla Dienekes Plaza Web oprócz zapytań do API #4 należy doliczyć ok. **375 req/s** ruchu HTTP dla samego kontenera front-endowego ECS).*

---

### 1.2. Dekompozycja ruchu na API i endpointy (`/stats`, `/auth`, `/payments`)

Zgodnie z profilem ruchu (**89,0% `/stats**`, **9,4% `/auth**`, **1,6% `/payments**`), obciążenie poszczególnych klastrów API rozkłada się następująco (wartości w nawiasach oznaczają bezpieczny *Sizing Envelope*):

| Klaster | Obsługiwane gry | Silnik DB | Łączny Peak RPS | `/stats` (89,0%) | `/auth` (9,4%) | `/payments` (1,6%) |
| --- | --- | --- | --- | --- | --- | --- |
| **API #1** | Pythodorus 3 | Aurora PostgreSQL | **24 188** *(24 188)* | 21 527 *(21 527)* | 2 274 *(2 274)* | 387 *(387)* |
| **API #2** | Theognis per Megara | Aurora PostgreSQL | **323** *(750)* | 287 *(668)* | 30 *(71)* | 5 *(12)* |
| **API #3** | Agrippa Mosa + Mosa 2 | Aurora PostgreSQL | **16 770** *(17 250)* | 14 925 *(15 353)* | 1 576 *(1 622)* | 268 *(276)* |
| **API #4** | Dienekes Plaza (App + Web) | Aurora MySQL | **1 935** *(4 125)* | 1 722 *(3 671)* | 182 *(388)* | 31 *(66)* |
| **RAZEM** | **6 gier (5 Android, 1 Web)** | — | **43 215** *(46 313)* | **38 461** *(41 219)* | **4 062** *(4 355)* | **691** *(741)* |

**Kluczowe wnioski dla architektury:**

1. **Asymetria skali:** API #1 i API #3 obsługują łącznie **94,8%** całego ruchu (40 958 req/s). API #2 i API #4 są o rząd wielkości mniejsze, ale muszą zachować identyczny standard odporności (DR, izolacja), ponieważ awaria któregokolwiek z nich psuje wspólne SLI.
2. **Dominacja zapisu/odczytu statystyk:** Blisko **41,2 tys. req/s** na `/stats` w szczycie oznacza ponad **106 milionów żądań na godzinę**. Bezpośrednie uderzanie każdego z tych zapytań w relacyjną bazę danych (szczególnie zapisów `UPDATE` na tych samych wierszach graczy) wywołałoby blokady na poziomie wierszy (*row-level lock contention*) i wysycenie IOPS.
3. **Krytyczność płatności:** **741 req/s** na `/payments` to stosunkowo niewielki wolumen dla nowoczesnej bazy relacyjnej, ale każde odrzucone lub zdublowane żądanie to bezpośrednia strata finansowa i reklamacje. Ta ścieżka musi być fizycznie odizolowana od korków na `/stats`.

---

### 1.3. Model SLI / SLO i zarządzanie Error Budgetem

Wymaganie wejściowe to **SLI ≥ 99,5%** w skali miesiąca (30 dni = 43 200 minut).

* **Całkowity miesięczny Error Budget (dla 99,5%):** **216 minut** (3 godziny i 36 minut) niedostępności lub błędów serwera (HTTP 5xx / przekroczenie czasu odpowiedzi).
* **Wpływ celów DR:** Nasze RTO wynosi **15 minut**. Oznacza to, że jedna pełna awaria regionu i przełączenie ruchu do regionu zapasowego zużywa **~7% całego miesięcznego budżetu błędów**.

Aby nigdy nie naruszyć zewnętrznego progu 99,5%, definiujemy wewnętrzne cele **SLO (Service Level Objectives)** zróżnicowane według krytyczności biznesowej endpointów:

| Ścieżka / Komponent | Wewnętrzne SLO | Miesięczny Error Budget | Docelowe opóźnienie (p99) | Uzasadnienie inżynieryjne |
| --- | --- | --- | --- | --- |
| **`/payments`** | **99,99%** | 4,32 min | < 400 ms | Transakcje finansowe; brak tolerancji na utratę żądań. |
| **`/auth`** | **99,95%** | 21,60 min | < 100 ms | Bramka wejścia do gry; awaria odcina 100% graczy. |
| **`/stats`** | **99,90%** | 43,20 min | < 150 ms | Najwyższy wolumen; dopuszczalna chwilowa kolejka lub *graceful degradation*. |
| **Dienekes Plaza Web** | **99,90%** | 43,20 min | < 250 ms | Warstwa prezentacji chroniona przez CloudFront (cache). |

**Definicja SLI (Success Rate):**


$$\text{SLI} = \frac{\text{Liczba poprawnych żądań (HTTP 2xx/3xx/4xx z wyłączeniem 429) poniżej progu latency p99}}{\text{Całkowita liczba żądań na poziomie ALB}} \times 100\%$$

*(Uwaga: Błędy klienta HTTP 400/401/403 nie obciążają naszego budżetu błędów, natomiast błędy `429 Too Many Requests` wynikające z przeciążenia naszej infrastruktury — tak).*

---

### 1.4. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 1)

Poniższe stałe stanowią kontrakt wejściowy (`variables.tf` / `locals.tf`), na podstawie którego będziemy wymiarować kolejne warstwy infrastruktury:

```hcl
locals {
  traffic_profile = {
    api_1 = { peak_rps = 24188, stats_rps = 21527, auth_rps = 2274, payments_rps = 387, db_engine = "aurora-postgresql" }
    api_2 = { peak_rps = 750,   stats_rps = 668,   auth_rps = 71,   payments_rps = 12,  db_engine = "aurora-postgresql" }
    api_3 = { peak_rps = 17250, stats_rps = 15353, auth_rps = 1622, payments_rps = 276, db_engine = "aurora-postgresql" }
    api_4 = { peak_rps = 4125,  stats_rps = 3671,  auth_rps = 388,  payments_rps = 66,  db_engine = "aurora-mysql" }
  }
  slo_targets = {
    external_sli = 0.995
    payments_slo = 0.9999
    auth_slo     = 0.9995
    stats_slo    = 0.9990
  }
}

```

---

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

---

## Sekcja 3: Warstwa Obliczeniowa — Amazon ECS i Izolacja Domen

### 3.1. Wybór Runtime: AWS Fargate (ARM64 / Graviton)

Przy zespole 44 inżynierów i nieograniczonym budżecie największym kosztem operacyjnym nie jest rachunek za vCPU, lecz czas poświęcony na łatanie systemów operacyjnych, zarządzanie klastrami EC2 i problem *bin-packingu* (dopasowywania kontenerów do maszyn wirtualnych).

* **Decyzja:** Wybieramy **AWS Fargate** na procesorach **AWS Graviton (ARM64)**.
* **Uzasadnienie inżynieryjne:**
* Każde zadanie (*ECS Task*) działa w odizolowanym mikro-środowisku Firecracker VM — brak współdzielenia jądra systemu między kontenerami.
* Brak narzutu na aktualizacje AMI, skalowanie węzłów (*Cluster Autoscaler / Karpenter*) czy puste zasoby czekające w rezerwie.
* Lepsza wydajność jednowątkowa i niższe opóźnienia p99 dla operacji kryptograficznych (weryfikacja tokenów JWT na `/auth` i TLS) niż na starszych architekturach x86.



---

### 3.2. Strategia Izolacji i Ochrona przed *Blast Radius*

Stosujemy dwupoziomową izolację błędów:

1. **Poziom 1 — Dedykowane Klastry ECS (5 klastrów):**
* `ecs-api-1` (*Pythodorus 3*)
* `ecs-api-2` (*Theognis per Megara*)
* `ecs-api-3` (*Agrippa Mosa* + *Agrippa Mosa 2*)
* `ecs-api-4` (*Dienekes Plaza* Android + Web API)
* `ecs-web-dienekes` (warstwa front-end/BFF aplikacji *Dienekes Plaza Web*)


2. **Poziom 2 — Separacja usług po ścieżkach HTTP (Path-Based Routing na ALB):**
* W każdym klastrze API ruch z Application Load Balancera (ALB) jest rozdzielany na poziomie reguł ścieżek (`Listener Rules`) na trzy osobne *Target Groups* i trzy osobne serwisy ECS:
* `service-stats` (obsługuje `/v1/stats/*`)
* `service-auth` (obsługuje `/v1/auth/*`)
* `service-payments` (obsługuje `/v1/payments/*`)


* **Dlaczego to kluczowe?** Wszystkie trzy serwisy mogą korzystać z tego samego obrazu kontenera (uruchamianego z inną zmienną środowiskową `SERVICE_ROLE=payments|auth|stats`), ale mają osobne limity CPU/RAM, osobne reguły autoskalowania i osobne kolejki połączeń. Nawet całkowite zawieszenie procesów na `/stats` nie wpływa na dostępność `/payments`.



---

### 3.3. Wymiarowanie Zadań (*Task Sizing*) i Kalkulacja Mocy

Do obliczeń przyjmujemy konserwatywny standard wydajności dla pojedynczego zadania Fargate o rozmiarze **`2 vCPU / 4 GB RAM`** (wystarczający zapas przepustowości sieciowej i pamięci na lokalny cache kluczy publicznych JWT oraz pule połączeń HTTP/2):

* Dla lekkich operacji asynchronicznych (`/stats`, `/auth`): **400 RPS na zadanie** przy docelowym obciążeniu CPU ~55% (zostawiamy 45% zapasu na skoki ruchu i *Garbage Collection*).
* Dla operacji synchronicznych z zewnętrzną weryfikacją (`/payments`) oraz renderowania SSR (*Web*): **200 RPS na zadanie**.
* **Zasada High Availability:** Każdy serwis posiada minimum **3 zadania** (po 1 na każdą Strefę Dostępności AZ), a krytyczne ścieżki `/payments` oraz duże klastry mają wyższe minima, aby awaria jednej AZ (utrata 33% mocy) nie wywołała kolejkowania żądań przed zadziałaniem autoskalowania.

#### Tabela wymiarowania dla Regionu Głównego (`eu-central-1`):

| Klaster ECS | Serwis (Ścieżka) | Peak RPS (Envelope) | Rozmiar Zadania | Min Zadań (Off-Peak) | Zadania w Szczycie (Peak) | Max Zadań (Surge Ceiling) | Max vCPU |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **`ecs-api-1`** | `stats` | 21 527 | 2 vCPU / 4 GB | 24 | 54 | 90 | 180 |
|  | `auth` | 2 274 | 2 vCPU / 4 GB | 6 | 6 | 15 | 30 |
|  | `payments` | 387 | 2 vCPU / 4 GB | 6 | 6 | 12 | 24 |
| **`ecs-api-2`** | `stats` | 668 | 2 vCPU / 4 GB | 3 | 3 | 8 | 16 |
|  | `auth` | 71 | 2 vCPU / 4 GB | 3 | 3 | 6 | 12 |
|  | `payments` | 12 | 2 vCPU / 4 GB | 3 | 3 | 6 | 12 |
| **`ecs-api-3`** | `stats` | 15 353 | 2 vCPU / 4 GB | 18 | 39 | 65 | 130 |
|  | `auth` | 1 622 | 2 vCPU / 4 GB | 6 | 6 | 12 | 24 |
|  | `payments` | 276 | 2 vCPU / 4 GB | 6 | 6 | 10 | 20 |
| **`ecs-api-4`** | `stats` | 3 671 | 2 vCPU / 4 GB | 6 | 10 | 20 | 40 |
|  | `auth` | 388 | 2 vCPU / 4 GB | 3 | 3 | 8 | 16 |
|  | `payments` | 66 | 2 vCPU / 4 GB | 3 | 3 | 6 | 12 |
| **`ecs-web`** | `web-ssr-bff` | 375 | 2 vCPU / 4 GB | 6 | 6 | 15 | 30 |
| **RAZEM** | **13 serwisów** | **46 688** | — | **93** | **152** | **273** | **546** |

*(W regionie zapasowym DR `eu-west-1` utrzymujemy przez całą dobę pulę **Warm Standby** równą kolumnie **Min Zadań (93 zadania = 186 vCPU)**, gotową do natychmiastowego przyjęcia ruchu i przeskalowania w górę w ciągu 60–90 sekund).*

---

### 3.4. Architektura Aplikacji Web (*Dienekes Plaza Web*) w ECS

Serwis `ecs-web-dienekes` działa jako bezstanowy serwer **SSR / BFF (Backend-for-Frontend)**:

* **Bezstanowość kontenerów:** Kontenery Web nie przechowują sesji w pamięci lokalnej. Stan sesji przeglądarkowej oraz ciasteczka `HttpOnly` są walidowane przez klaster **ElastiCache (Valkey/Redis)** oraz **API #4**.
* **Odciążenie statyków:** Podczas budowania obrazu kontenera (CI/CD), wszystkie zasoby statyczne (pliki JS, CSS, czcionki, obrazy gry) są eksportowane bezpośrednio do bucketu **Amazon S3** wystawionego przez **CloudFront**. Kontenery ECS obsługują wyłącznie generowanie początkowego HTML oraz warstwę BFF tłumaczącą żądania przeglądarkowe na wywołania wewnętrzne do `API #4` (zabezpieczenie przed CSRF i ukrycie wewnętrznych endpointów API).

---

### 3.5. Polityki Autoskalowania i Ochrona przed Zimnym Startem

Poleganie wyłącznie na reaktywnym autoskalowaniu po CPU jest zbyt wolne przy gwałtownych szczytach dobowych graczy mobilnych (np. wieczorne premiery eventów o 19:00 CET). Stosujemy **trzywarstwowe autoskalowanie**:

1. **Scheduled Scaling (Skalowanie predykcyjne):** Codziennie na 30 minut przed europejskim oknem szczytu podnosimy `desired_count` serwisów `stats` i `auth` do poziomu **80% mocy szczytowej**, aby kontenery były już rozgrzane (wypełnione pule połączeń, załadowane certyfikaty i klucze JWT).
2. **Target Tracking Scaling (Skalowanie ciągłe):** Utrzymuje średnie obciążenie CPU na poziomie **55%** oraz liczbę żądań na cel ALB (`ALBRequestCountPerTarget`) na poziomie **350 req/s** (dla `stats`/`auth`) lub **180 req/s** (dla `payments`).
3. **Graceful Shutdown & Deregistration Delay:**
* Na Target Groupach ustawiamy `deregistration_delay = 15s` (zamiast domyślnych 300s), co przyspiesza zwalnianie starych zadań podczas wdrożeń.
* Aplikacje w kontenerach przechwytują sygnał `SIGTERM`, kończą aktywne transakcje HTTP (szczególnie `/payments`) i zamykają pule połączeń przed wyłączeniem kontenera.



---

### 3.6. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 3)

```hcl
locals {
  ecs_clusters = {
    api_1 = {
      vpc_key = "core_gaming"
      services = {
        stats    = { cpu = 2048, memory = 4096, min = 24, max = 90, rps_target = 350, path = "/v1/stats/*" }
        auth     = { cpu = 2048, memory = 4096, min = 6,  max = 15, rps_target = 350, path = "/v1/auth/*" }
        payments = { cpu = 2048, memory = 4096, min = 6,  max = 12, rps_target = 180, path = "/v1/payments/*" }
      }
    }
    api_2 = {
      vpc_key = "standard_gaming"
      services = {
        stats    = { cpu = 2048, memory = 4096, min = 3, max = 8, rps_target = 350, path = "/v1/stats/*" }
        auth     = { cpu = 2048, memory = 4096, min = 3, max = 6, rps_target = 350, path = "/v1/auth/*" }
        payments = { cpu = 2048, memory = 4096, min = 3, max = 6, rps_target = 180, path = "/v1/payments/*" }
      }
    }
    api_3 = {
      vpc_key = "core_gaming"
      services = {
        stats    = { cpu = 2048, memory = 4096, min = 18, max = 65, rps_target = 350, path = "/v1/stats/*" }
        auth     = { cpu = 2048, memory = 4096, min = 6,  max = 12, rps_target = 350, path = "/v1/auth/*" }
        payments = { cpu = 2048, memory = 4096, min = 6,  max = 10, rps_target = 180, path = "/v1/payments/*" }
      }
    }
    api_4 = {
      vpc_key = "standard_gaming"
      services = {
        stats    = { cpu = 2048, memory = 4096, min = 6, max = 20, rps_target = 350, path = "/v1/stats/*" }
        auth     = { cpu = 2048, memory = 4096, min = 3, max = 8,  rps_target = 350, path = "/v1/auth/*" }
        payments = { cpu = 2048, memory = 4096, min = 3, max = 6,  rps_target = 180, path = "/v1/payments/*" }
      }
    }
    web_dienekes = {
      vpc_key = "standard_gaming"
      services = {
        frontend = { cpu = 2048, memory = 4096, min = 6, max = 15, rps_target = 180, path = "/*" }
      }
    }
  }
}

```

---

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

---

## Sekcja 5: Architektura Krytycznych Ścieżek Biznesowych (`/stats`, `/auth`, `/payments`)

### 5.1. Ścieżka `/stats` (89,0% ruchu — 41 219 Peak RPS)

**Cel:** Opóźnienie **p99 < 150 ms**, SLO **99,90%**, gwarancja *Read-Your-Own-Writes* (gracz natychmiast widzi swój wynik po meczu) bez zabijania bazy relacyjnej tysiącami blokad na wierszach.

#### Architektura przepływu (Wzorzec *Cache-Aside + Write-Behind*):

1. **Odczyt statystyk (`GET /v1/stats/*`):**
* Serwis `service-stats` odpytuje klaster **ElastiCache (Valkey)** (czas odpowiedzi < 2 ms, docelowy *Cache Hit Ratio* > 95%).
* W przypadku *Cache Miss* (np. powrót gracza po kilku dniach), żądanie trafia przez **RDS Proxy (Read-Only)** do repliki odczytowej Aurory, a wynik zapisywany jest w Valkey z **TTL = 24 godziny** (dla gorących profili) oraz losowym *jitterem* (±15 min), aby uniknąć jednoczesnego wygasania kluczy (*Cache Stampede*).


2. **Zapis statystyk (`POST/PUT /v1/stats/*`):**
* **Krok 1 (Natychmiastowa widoczność):** Kontener atomowo aktualizuje stan gracza w **Valkey** (np. operacje `HINCRBY` / `ZADD` dla rankingów).
* **Krok 2 (Asynchroniczne buforowanie):** Kontener wysyła zdarzenie zmiany stanu do dedykowanej kolejki **Amazon SQS** (osobna kolejka per API) i natychmiast zwraca graczowi kod `202 Accepted` / `200 OK` (całość trwa < 15 ms).
* **Krok 3 (Zapis wsadowy do Aurory):** Dedykowany, lekki serwis roboczy (`ecs-worker-stats`) pobiera wiadomości paczkami, grupuje je w pamięci przez **maksymalnie 2 sekundy** (lub do zebrania 500 unikalnych graczy) i wykonuje jedno zapytanie zbiorcze do instancji *Writer* Aurory:
* PostgreSQL: `INSERT INTO player_stats ... ON CONFLICT (player_id) DO UPDATE SET ...`
* MySQL (API #4): `INSERT INTO player_stats ... ON DUPLICATE KEY UPDATE ...`





**Dlaczego to działa przy RPO ≤ 5 min?**
Opóźnienie między przyjęciem żądania przez API a trwałym zapisem w Aurorze wynosi średnio **2–4 sekundy** (zostaje ponad 4 minuty zapasu względem limitu RPO 5 min). Jednocześnie zamieniamy **41 219 małych zapisów/s** na około **80–100 zoptymalizowanych zapytań wsadowych/s**. Jeśli baza chwilowo zwolni, kolejka SQS bezpiecznie wchłonie ruch (*backpressure*), a nieudane paczki po 3 próbach trafiają do **Dead Letter Queue (DLQ)** do automatycznego ponowienia.

---

### 5.2. Ścieżka `/auth` (9,4% ruchu — 4 355 Peak RPS)

**Cel:** Opóźnienie **p99 < 100 ms**, SLO **99,95%**, odporność na lawinowe logowania po wydaniu aktualizacji gry (*Thundering Herd*).

#### Architektura bezstanowa i współdzielenie sesji:

1. **Weryfikacja żądań w locie (Zero zapytań do bazy):**
* Po zalogowaniu gracz otrzymuje krótkotrwały **Access Token (JWT, ważny 15 minut)** podpisany asymetrycznie algorytmem **ES256 (ECDSA P-256)** oraz długotrwały **Refresh Token (ważny 30 dni)**.
* Kontenery ECS pobierają klucz publiczny z **AWS Secrets Manager / KMS** przy starcie i cachują go w pamięci RAM. Każde kolejne wywołanie `/stats` czy `/payments` weryfikuje podpis JWT lokalnie w czasie **< 0,5 ms**, bez dotykania bazy danych czy sieci.


2. **Logowanie i odświeżanie tokenów w Amazon DynamoDB Global Tables:**
* Zamiast obciążać relacyjną Aurorę ciągłymi zapisami sesji, stan logowań, *Refresh Tokeny* oraz listę unieważnionych sesji przechowujemy w **Amazon DynamoDB** w trybie **On-Demand** z włączoną replikacją **Global Tables** między `eu-central-1` a `eu-west-1`.
* **Korzyść operacyjna:** DynamoDB zapewnia jednocyfrowe opóźnienia (2–5 ms) przy dowolnym skoku ruchu, natywny mechanizm **TTL** automatycznie usuwa wygasłe sesje bez obciążania systemu, a replikacja między regionami działa w trybie *Active-Active* (< 1 s). Podczas awarii regionu gracz nie musi logować się ponownie.



---

### 5.3. Ścieżka `/payments` (1,6% ruchu — 741 Peak RPS)

**Cel:** Opóźnienie **p99 < 400 ms**, SLO **99,99%**, gwarancja **ACID** i absolutny zakaz podwójnego obciążenia gracza lub utraty zakupionego przedmiotu.

#### Wzorzec *Idempotent Execution + Transactional Outbox*:

1. **Wymuszona Idempotencja na wejściu:**
* Klient gry/Web musi przesłać nagłówek `Idempotency-Key` (UUIDv7 wygenerowany przy kliknięciu „Kup”).
* Serwis `service-payments` sprawdza ten klucz w **Valkey** (`SET key "IN_PROGRESS" NX EX 300`). Jeśli klient ponowi identyczne żądanie (np. przez zerwane połączenie w metrze), API zwraca zapisany wynik poprzedniej transakcji zamiast przetwarzać płatność drugi raz.


2. **Weryfikacja zewnętrzna i transakcja ACID w Aurorze:**
* Po pozytywnej weryfikacji tokenu zakupu w Google Play Developer API lub bramce płatniczej Web (szczegóły izolacji w Sekcji 6), serwis otwiera transakcję na instancji **Writer Aurory** (przez RDS Proxy Read/Write) i w jednym bloku `BEGIN ... COMMIT` wykonuje trzy operacje:
1. Wstawia rekord do `payment_transactions` (z ograniczeniem `UNIQUE (idempotency_key)` i `UNIQUE (external_transaction_id)` jako ostateczną barierą na poziomie silnika SQL).
2. Aktualizuje saldo waluty premium / ekwipunek gracza w tabeli `player_wallets`.
3. Zapisuje zdarzenie rozliczeniowe w tabeli `outbox_events` (**Transactional Outbox**).




3. **Asynchroniczna dystrybucja zdarzeń:**
* Lekki proces w tle odczytuje nowe wiersze z `outbox_events` i publikuje je do kolejek analitycznych/audytowych, oznaczając je jako wysłane. Dzięki temu nawet chwilowa niedostępność systemów raportowych nigdy nie cofnie transakcji zakupu gracza.



---

### 5.4. Podsumowanie separacji wzorców per ścieżka

| Ścieżka | Wzorzec spójności | Główny magazyn odczytu | Główny magazyn zapisu | Strategia przy przeciążeniu bazy |
| --- | --- | --- | --- | --- |
| **`/stats`** | *Eventual Consistency* (< 4s) | ElastiCache (Valkey) | Valkey -> SQS -> Aurora (Batch) | Buforowanie w SQS (kolejka rośnie, API nadal zwraca `202 OK`). |
| **`/auth`** | *Strong / Multi-Region* | Pamięć lokalna ECS (JWT) | DynamoDB Global Tables | Pełna niezależność od Aurory; autoryzacja działa nawet podczas awarii SQL. |
| **`/payments`** | *Strict ACID* | Aurora Writer (RDS Proxy) | Aurora Writer (RDS Proxy) | Priorytetowy dostęp do puli połączeń; odcięcie ruchu `/stats` przy degradacji. |

---

### 5.5. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 5)

```hcl
locals {
  stats_queues = {
    api_1 = { visibility_timeout = 30, max_receive_count = 3, batch_size = 500, flush_window_sec = 2 }
    api_2 = { visibility_timeout = 30, max_receive_count = 3, batch_size = 100, flush_window_sec = 2 }
    api_3 = { visibility_timeout = 30, max_receive_count = 3, batch_size = 500, flush_window_sec = 2 }
    api_4 = { visibility_timeout = 30, max_receive_count = 3, batch_size = 200, flush_window_sec = 2 }
  }

  dynamodb_auth_tables = {
    billing_mode     = "PAY_PER_REQUEST" # On-Demand dla nagłych skoków logowań
    ttl_attribute    = "expires_at"
    replica_regions  = ["eu-central-1", "eu-west-1"]
    point_in_time_recovery = true
  }
}

```

---

## Sekcja 6: Integracje Zewnętrzne (3rd-Party), Współdzielona Tożsamość i Odporność Klienta

### 6.1. Izolacja Zależności Zewnętrznych (*3rd-Party SPOFs*)

Ścieżki `/auth` i `/payments` muszą komunikować się z zewnętrznymi systemami: **Google Play Games Services** (weryfikacja tokenów OAuth), **Google Play Developer API** (weryfikacja paragonów Android) oraz **bramkami płatniczymi Web** (np. Stripe / Adyen dla *Dienekes Plaza Web*). Bez izolacji, 10-sekundowe opóźnienie po stronie Google zablokuje wątki kontenerów ECS i położy nasze API.

#### Mechanizmy ochrony na styku ze światem zewnętrznym:

1. **Dedykowane pule wątków i twarde timeouty:** Wywołania HTTP do dostawców zewnętrznych używają osobnej puli połączeń z rygorystycznym limitem czasu (**Connection Timeout = 1,5 s**, **Read Timeout = 3,0 s**).
2. **Circuit Breaker per dostawca (w Valkey):** Jeśli odsetek błędów lub timeoutów od Google Play Billing przekroczy **20% w oknie 10 sekund**, Circuit Breaker przechodzi w stan `OPEN` i natychmiast przełącza ścieżkę płatności w tryb asynchroniczny (*Pending Verification*).
3. **Asynchroniczna Rekoncyliacja Płatności (Webhook + Polling):**
* Gdy bramka płatnicza lub Google API odpowiada wolno lub zwraca `503`, API zapisuje transakcję ze statusem `PENDING_EXTERNAL`, wrzuca zadanie do kolejki **SQS Reconciliation Queue** (z opóźnieniem 15s -> 60s -> 300s) i informuje klienta gry o przetwarzaniu zakupu.
* Dodatkowo nasłuchujemy na **Google Play Real-Time Developer Notifications (RTDN)** (przez Pub/Sub -> HTTPS Webhook na ALB) oraz webhooki bramki Web, aby natychmiast księgować zwroty (*chargebacks*), anulowania i opóźnione płatności.



---

### 6.2. Współdzielona Tożsamość i Izolacja Danych (API #3 oraz API #4)

Dwa z naszych klastrów obsługują więcej niż jeden kanał lub tytuł:

* **API #3:** współdzielony przez *Agrippa Mosa* (50M MAU) i *Agrippa Mosa 2* (2M MAU).
* **API #4:** współdzielony przez *Dienekes Plaza* (Android, 5M MAU) oraz *Dienekes Plaza Web* (1M MAU).

#### Architektura konta i ochrona przed wzajemnym zakłócaniem:

1. **Unified Player ID (UUIDv7) + Federated Identities:**
* Każde konto otrzymuje wewnętrzny identyfikator `player_id` (UUIDv7, sortowalny po czasie, co zapobiega fragmentacji indeksów B-Tree w PostgreSQL i MySQL).
* W tabeli `player_identities` (w DynamoDB Global Tables dla szybkiego logowania) mapujemy zewnętrzne identyfikatory (`google_play_id`, `email_hash`, `apple_id`) na jeden `player_id`.
* **Dla API #4 (Cross-Platform Android + Web):** gracz logujący się na Androidzie i w przeglądarce otrzymuje ten sam `player_id`, współdzieląc postępy i portfel. W warstwie Web (BFF) token JWT jest przechowywany w zaszyfrowanym ciasteczku `HttpOnly; Secure; SameSite=Strict` z ochroną przed CSRF, podczas gdy klient Android przesyła ten sam token w nagłówku `Authorization: Bearer`.


2. **Izolacja domenowa w API #3 (*Agrippa Mosa* vs *Agrippa Mosa 2*):**
* **Wspólne konto, oddzielne postępy:** Obie gry dzielą tabelę `accounts` (jeden login gracza w uniwersum *Agrippa Mosa*), ale tabele statystyk, ekwipunku i płatności mają osobne schematy SQL (`schema_mosa1`, `schema_mosa2`) oraz osobne kolejki SQS dla `/stats`.
* **Ochrona budżetu zasobów:** W nagłówkach JWT zaszywamy pole `app_id` (`mosa_1` vs `mosa_2`). Jeśli nowa gra *Agrippa Mosa 2* wygeneruje niespodziewany szturm zapytań przez błąd w kodzie klienta, limiter w Valkey dławi ruch wyłącznie dla `app_id = mosa_2`, chroniąc 50M graczy w *Agrippa Mosa*.



---

### 6.3. Odporność po Stronie Klienta Mobilnego (*Client-Side Resilience Contract*)

Przy 11,6 mln graczy mobilnych dziennie, najczęstszym źródłem sztucznych ataków DDoS na własne serwery jest źle napisany kod sieciowy w kliencie gry po utracie zasięgu (np. wyjazd pociągu z tunelu).

Wprowadzamy obowiązkowy **kontrakt sieciowy SDK** dla wszystkich 5 gier Android oraz klienta Web:

1. **Exponential Backoff + Full Jitter:**
* Przy błędzie sieciowym, timeoutcie lub kodzie HTTP `503`/`429`, klient nie może ponowić żądania natychmiast.
* Czas oczekiwania wyliczany jest wzorem: $\text{sleep} = \text{random}(0, \min(\text{cap}, \text{base} \times 2^{\text{attempt}}))$ (gdzie $\text{base} = 500\text{ ms}$, $\text{cap} = 30\text{ s}$, maks. 5 prób). Rozprasza to falę ponowień w czasie i eliminuje efekt *Thundering Herd*.


2. **Lokalny bufor zdarzeń `/stats` na urządzeniu:**
* Ponieważ `/stats` stanowi 89% ruchu, klient gry nie wysyła każdego pojedynczego zdarzenia osobno. Zdarzenia są grupowane w lokalnej bazie SQLite na urządzeniu i wysyłane paczką co **15–30 sekund** (lub na koniec meczu) z użyciem kompresji **Gzip/Brotli** oraz nagłówka `Batch-Id` (zapobiegającego duplikacji przy ponowieniu).
* Jeśli serwer zwróci `429 Too Many Requests` z nagłówkiem `Retry-After: 60`, klient wstrzymuje wysyłkę statystyk na 60 sekund, bez przerywania rozgrywki graczowi.


3. **Kolejka płatności na urządzeniu:**
* Token zakupu otrzymany z Google Play Billing jest natychmiast zapisywany w trwałej pamięci urządzenia przed wysłaniem do `/payments`. Klient ponawia wysyłkę z tym samym `Idempotency-Key` aż do otrzymania statusu `CONFIRMED` lub `REJECTED` od naszego API (nigdy nie konsumuje zakupu w Google Play przed potwierdzeniem zapisu w naszej bazie).



---

### 6.4. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 6)

```hcl
locals {
  reconciliation_queues = {
    for api_key in ["api_1", "api_2", "api_3", "api_4"] : api_key => {
      delay_seconds              = 15
      visibility_timeout_seconds = 60
      max_receive_count          = 5 # Ponowienia z backoffem do 15 min
      message_retention_seconds  = 1209600 # 14 dni na ręczną inspekcję DLQ
    }
  }

  client_rate_limits_per_minute = {
    stats_per_player    = 30  # Średnio 9/min; 30/min daje ponad 3x zapasu na szczyty
    auth_per_ip         = 20  # Ochrona przed brute-force / credential stuffing
    payments_per_player = 10  # Ochrona przed pętlami błędów w SDK płatności
  }
}

```

---

## Sekcja 7: Odporność, High Availability i Disaster Recovery

### 7.1. Dlaczego *Warm Standby* (Active-Passive), a nie *Active-Active Multi-Region*?

Przy nieograniczonym budżecie kuszącą pułapką jest budowa architektury *Active-Active* (jednoczesny zapis do baz w Frankfurcie i Irlandii). W systemach gamingowych z wymogami ACID (`/payments`) i intensywnymi aktualizacjami stanu (`/stats`) jest to **groźny antywzorzec**:

* **Złożoność i spójność:** Rozproszone zapisy wieloregionowe w SQL (np. CockroachDB czy własne shardingi) drastycznie podnoszą opóźnienia p99 (wymagany konsensus między regionami przez sieć WAN ~22 ms) i generują ryzyko konfliktów przy jednoczesnych zakupach lub aktualizacji ekwipunku.
* **Pragmatyzm Principal Engineera:** Skoro wymagane **RTO wynosi 15 minut**, model **Warm Standby** (gdzie region zapasowy ma już uruchomione pełnowymiarowe instancje baz danych, puste klastry Valkey oraz pulę 93 rozgrzanych kontenerów Fargate) daje nam **100% bezpieczeństwa ACID**, prostotę operacyjną pojedynczego punktu zapisu i realny czas odtworzenia poniżej 7 minut.

---

### 7.2. Gwarancja RPO ≤ 5 minut dla każdej warstwy danych

Aby nie stracić więcej niż 5 minut danych w przypadku nagłej, całkowitej awarii regionu Frankfurt (`eu-central-1`), zabezpieczamy trzy warstwy stanowe:

1. **Bazy relacyjne (Aurora Global Database):**
* Replikacja odbywa się bezpośrednio na poziomie warstwy dyskowej AWS (nie obciąża CPU) z opóźnieniem **< 1 sekundy**.
* Włączamy **Aurora Backtrack** (okno 24h) oraz ciągłe kopie zapasowe (**Point-in-Time Recovery — PITR**) w obu regionach, aby chronić się nie tylko przed awarią sprzętu, ale też przed błędnym wdrożeniem (np. przypadkowym `DELETE` bez `WHERE`).


2. **Sesje i uwierzytelnianie (DynamoDB Global Tables):**
* Działa natywnie w trybie *Active-Active* między Frankfurtem a Irlandią (opóźnienie replikacji **< 1 sekundy**). Przełączenie regionu nie wylogowuje graczy.


3. **Zdarzenia w locie na `/stats` (Kolejki SQS):**
* W normalnym trybie kolejka SQS opróżniana jest co **2 sekundy**, więc w przypadku nagłego odcięcia zasilania Frankfurtu tracimy maksymalnie 2 sekundy nieprzetworzonych statystyk (zapas 298 sekund względem RPO 5 min).
* **Zabezpieczenie przed korkiem przed awarią:** Monitorujemy metrykę `ApproximateAgeOfOldestMessage`. Jeśli opóźnienie przetwarzania SQS w `eu-central-1` przekroczy **60 sekund**, API automatycznie przełącza wysyłkę nowych paczek `/stats` na zapasową kolejkę SQS w regionie `eu-west-1` (*Cross-Region Spillover*), gwarantując, że RPO nigdy nie zbliży się do 5 minut.



---

### 7.3. Budżet Czasowy Failoveru (RTO ≤ 15 min -> Cel: 6 min 30 s)

Przełączenie między regionami jest orkiestrowane przez **AWS Systems Manager (SSM) Automation Runbook** oraz **Amazon Route 53 Application Recovery Controller (ARC)** (który działa na płaszczyźnie danych AWS i nie zawiedzie nawet wtedy, gdy API zarządzające AWS w Frankfurcie przestanie odpowiadać).

| Etap Failoveru | Czas trwania | Skumulowany czas (RTO) | Wykonywane akcje techniczne |
| --- | --- | --- | --- |
| **1. Detekcja i Decyzja** | 90 s | **01:30** | Złożone alarmy CloudWatch + Synthetics wykrywają spadek SLI < 99,0% w 3 kolejnych oknach 30s. Dyżurny SRE zatwierdza przełączenie 1 kliknięciem (ochrona przed *split-brain* przy fałszywym alarmie). |
| **2. Przełączenie Ruchu Edge** | 30 s | **02:00** | **Route 53 ARC** zmienia wagi w **Global Accelerator** (`eu-central-1` = 0%, `eu-west-1` = 100%). **CloudFront** przełącza *Origin* dla *Dienekes Plaza Web* na ALB w Irlandii. |
| **3. Promocja Bazy Danych** | 90 s | **03:30** | Wywołanie `FailoverGlobalCluster` (lub `RemoveFromGlobalCluster` przy całkowitej śmierci regionu) promuje instancje w `eu-west-1` na nowe klastry *Writer*. **RDS Proxy** w Irlandii automatycznie kieruje zapisy na nowych liderów. |
| **4. Skalowanie ECS i Rozgrzewanie** | 180 s | **06:30** | Kontenery Fargate w `eu-west-1` (już uruchomione w liczbie 93 szt.) przyjmują ruch i skalują się do docelowych 152 szt., przy jednoczesnym stopniowym otwieraniu limitów na `/stats`. |

*(Zostaje **8 minut i 30 sekund** bezpiecznego bufora na nieprzewidziane opóźnienia sieciowe przed naruszeniem SLA 15 minut).*

---

### 7.4. Rozgrzewanie Zimnego Cache'u (*Cold Cache Protection*) po Failoverze

Największym zabójcą systemów po przełączeniu DR jest **pusty klaster Valkey (Redis)** w regionie zapasowym. Nie replikujemy zawartości RAM między regionami (zbyt duże narzuty sieciowe i ryzyko przeniesienia uszkodzonych danych). Gdy 41,2k req/s z `/stats` uderzy w pusty Valkey w Irlandii, 100% zapytań wygeneruje *Cache Miss* i trafi prosto w bazę Aurora, powodując jej natychmiastowe przeciążenie.

Wdrażamy **trzy mechanizmy ochronne**:

1. **Request Coalescing (Wzorzec *Singleflight* w kodzie API):** Jeśli w tej samej milisekundzie 50 wątków zapyta o profil tego samego gracza (którego nie ma w Valkey), tylko **1 zapytanie** leci do Aurory, a pozostałe 49 czeka na jego wynik z pamięci lokalnej kontenera.
2. **Progresywny *Load Shedding* na `/stats` (T+0 do T+5 min po failoverze):**
* Serwisy `/payments` i `/auth` od pierwszej sekundy działają na **100% przepustowości**.
* Serwis `service-stats` uruchamia się z flagą `DR_WARMUP_MODE=true` (sterowaną przez AWS AppConfig), która stopniowo otwiera przepustowość odczytów: **30% w 1. minucie -> 60% w 3. minucie -> 100% w 5. minucie**. Nadmiarowe odczyty otrzymują `HTTP 429` z nagłówkiem `Retry-After: 20` (klient gry z Sekcji 6 grzecznie czeka i nie zrywa rozgrywki).


3. **Wstępne ładowanie TOP graczy (Background Pre-Warmer):** Zaraz po promocji bazy w `eu-west-1`, lekki worker pobiera z replik odczytowych Aurory profile 500 tys. najaktywniejszych graczy (logujących się w ciągu ostatnich 2 godzin) i wsadowo ładuje je do Valkey za pomocą `PIPELINE`.

---

### 7.5. Macierz Degradacji Usług (*Graceful Degradation* wewnątrz regionu)

Gdy pojedynczy komponent (np. kolejka SQS lub replika odczytowa) ulegnie degradacji wewnątrz `eu-central-1`, system nie pada jako całość, lecz świadomie poświęca mniej krytyczne funkcje, aby chronić budżet błędów SLI 99,5%:

| Priorytet | Ścieżka / Funkcja | Zachowanie podczas kryzysu | Wpływ na gracza |
| --- | --- | --- | --- |
| **P1 (Krytyczny)** | **`/payments`** | Zarezerwowana pula połączeń w RDS Proxy; automatyczne odcięcie ruchu `/stats`, jeśli obciążenie CPU bazy Writer przekroczy 85%. | Gracz zawsze może dokonać zakupu; zero utraconych transakcji. |
| **P2 (Wysoki)** | **`/auth`** | Działa całkowicie niezależnie od Aurory (JWT + DynamoDB). | Gracz zawsze może uruchomić i zalogować się do gry. |
| **P3 (Średni)** | **`/stats` (Zapisy)** | Przy spowolnieniu bazy dane gromadzą się w SQS (retencja do 14 dni); stan w Valkey aktualizuje się na bieżąco. | Gracz widzi postępy na żywo; zapis trwały w SQL następuje z opóźnieniem. |
| **P4 (Niski)** | **`/stats` (Rankingi / Historia)** | Włączenie trybu *Stale-If-Error* (zwracanie lekko nieaktualnych danych z cache lub wyłączenie globalnych tabel wyników). | Gra działa płynnie; globalne rankingi odświeżają się rzadziej. |

---

### 7.6. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 7)

```hcl
locals {
  dr_configuration = {
    primary_region = "eu-central-1"
    dr_region      = "eu-west-1"

    route53_arc = {
      cluster_name        = "gaming-eu-recovery-cluster"
      routing_controls    = ["api-1", "api-2", "api-3", "api-4", "web-dienekes"]
      safety_rule_min_active = 1 # Blokuje jednoczesne wyłączenie obu regionów
    }

    aurora_resilience = {
      backup_retention_period = 14 # dni
      backtrack_window        = 86400 # 24h w sekundach (dla Aurora MySQL/PG)
      deletion_protection     = true
    }

    warmup_ramp_up = {
      stage_1_percent  = 30
      stage_2_percent  = 60
      stage_3_percent  = 100
      step_interval_sec = 120
    }
  }
}

```

---

## Sekcja 8: Bezpieczeństwo, Zgodność (GDPR), Potok Analityczny (BI) i LiveOps

### 8.1. Zarządzanie Tożsamością, Szyfrowaniem i Sekretami

Przy 134M kont graczy i 44 inżynierach dostęp do danych musi być rygorystycznie odizolowany zarówno od sieci publicznej, jak i między poszczególnymi usługami:

1. **Zasada *Least Privilege* per Serwis ECS:**
* Każda z 13 usług ECS posiada własną rolę **IAM Task Role**. Przykładowo: kontener `service-stats` ma uprawnienia wyłącznie do zapisu w konkretnej kolejce SQS i klastrze Valkey swojego API — nie ma żadnych uprawnień do baz płatności ani sekretów innych gier.


2. **Szyfrowanie w tranzycie i w spoczynku (Multi-Region KMS):**
* Wymuszamy **TLS 1.3** na wszystkich ALB, CloudFront oraz połączeniach wewnętrznych (ECS -> RDS Proxy, ECS -> Valkey).
* Wszystkie bazy Aurora, kolejki SQS, tabele DynamoDB i buckety S3 są szyfrowane kluczami zarządzanymi przez klienta (**AWS KMS Customer Managed Keys — CMK**) w wariancie **Multi-Region (`mrk-*`)**, co gwarantuje natychmiastowe odszyfrowanie danych w Irlandii (`eu-west-1`) po przełączeniu DR.


3. **Automatyczna rotacja poświadczeń (AWS Secrets Manager):**
* Kontenery ECS nie posiadają haseł do baz danych w zmiennych środowiskowych. Uwierzytelniają się do **Amazon RDS Proxy** za pomocą **IAM Database Authentication** (krótkotrwałe tokeny kryptograficzne ważne 15 minut), a hasła techniczne między RDS Proxy a Aurorą są rotowane automatycznie co 30 dni przez Secrets Manager bez przerywania aktywnych sesji.



---

### 8.2. Ochrona przed Botami, Oszustwami i Nadużyciami API

Gry mobilne o skali 75M MAU są ciągłym celem farm botów, ataków *credential stuffing* na `/auth` oraz prób manipulacji wynikami na `/stats`:

1. **Weryfikacja integralności urządzeń (Google Play Integrity API):**
* Podczas logowania (`/auth`) i przed zainicjowaniem zakupu (`/payments`), klient Android przesyła token z **Google Play Integrity API**. Serwer weryfikuje, czy żądanie pochodzi z oryginalnej binarki gry pobranej ze sklepu Google Play i uruchomionej na niezmodyfikowanym urządzeniu (blokada emulatorów i zrootowanych skryptów).


2. **Ochrona przed *Replay Attacks* na `/stats` i `/payments`:**
* Każde żądanie modyfikujące stan zawiera nagłówki `X-Request-Timestamp` oraz `X-Request-Nonce` wraz z podpisem HMAC. Serwer odrzuca żądania starsze niż **60 sekund**, a zużyte wartości `Nonce` zapisuje w Valkey (z TTL = 65 s), uniemożliwiając przechwycenie i wielokrotne wysłanie tej samej paczki punktów.


3. **Wielowarstwowe filtrowanie na krawędzi (AWS WAF):**
* **Geo-blocking / Anomaly Detection:** automatyczne dławienie ruchu z centrów danych (AWS/GCP/Azure IP ranges — gracze mobilni i webowi łączą się z sieci operatorskich, nie z serwerowni).
* **Managed Rule Groups:** ochrona przed OWASP Top 10, SQL Injection oraz znanymi botnetami na poziomie ALB i CloudFront.



---

### 8.3. Zgodność z RODO (GDPR) w Infrastrukturze Europejskiej

Przetwarzanie danych osobowych (PII: adresy IP, identyfikatory urządzeń, powiązania kont Google/e-mail, historia płatności) wymaga rozwiązań odpornych na audyty prawne:

1. **Twarda blokada geograficzna (AWS Organizations SCP):**
* Na poziomie całej organizacji AWS nakładamy politykę **Service Control Policy (SCP)** blokującą tworzenie jakichkolwiek zasobów poza regionami `eu-central-1` i `eu-west-1` (z wyjątkiem globalnych usług brzegowych IAM/CloudFront/Route53). Daje to 100% gwarancji prawnej, że dane graczy nie opuszczą UE.


2. **Prawo do bycia zapomnianym (*Crypto-Shredding*):**
* Usunięcie konta gracza z żywej bazy Aurora i DynamoDB jest proste, ale RODO wymaga również usunięcia jego danych z kopii zapasowych i archiwów S3. Ponieważ backupy są niemodyfikowalne, stosujemy **Crypto-Shredding**:
* Dane wrażliwe gracza (PII) są szyfrowane dedykowanym dla danego użytkownika kluczem danych (**DEK — Data Encryption Key**) przechowywanym w osobnej tabeli `player_encryption_keys` w DynamoDB.
* Gdy gracz zażąda usunięcia konta (Art. 17 RODO), usuwamy jego rekordy z Aurory oraz **niszczymy jego klucz DEK w DynamoDB**. W efekcie jego dane we wszystkich kopiach zapasowych i archiwach S3 stają się kryptograficznie nieodczytywalne i bezużyteczne.




3. **Niemodyfikowalny audyt (Compliance Vault):**
* Wszystkie logi dostępu administratorów (**AWS CloudTrail**) oraz rejestry transakcji finansowych są przesyłane do dedykowanego konta audytowego z włączonym **S3 Object Lock (Compliance Mode)** na okres 5 lat (wymóg przepisów podatkowych i księgowych UE).



---

### 8.4. Odizolowany Potok Analityczny (BI) i LiveOps (Remote Config)

Przy 44 inżynierach i 6 grach, analitycy biznesowi oraz game designerzy będą codziennie analizować retencję (D1/D7/D30), balans rozgrywki i konwersję sklepów.

#### Zasada zero zapytań analitycznych na produkcyjnej Aurorze:

* **Strumieniowanie zdarzeń (Event Streaming):**
* Kontenery ECS oraz procesy *Transactional Outbox* wysyłają zdarzenia telemetryczne i biznesowe bezpośrednio do **Amazon Data Firehose** (bez obciążania baz SQL).
* Firehose automatycznie buforuje zdarzenia (co 60 sekund lub 64 MB), konwertuje je w locie do kolumnowego formatu **Apache Parquet** i zapisuje w hurtowni danych **Amazon S3 (Data Lake)** w strukturze **Apache Iceberg** (partycjonowanej po `game_id/year/month/day`).
* Zespoły BI odpytują te dane za pomocą **Amazon Athena** lub **Amazon Redshift Serverless** — nawet najbardziej skomplikowane zapytanie analityczne skanujące miliardy wierszy ma **0% wpływu** na wydajność produkcyjnych gier.



#### LiveOps i Feature Flags (AWS AppConfig):

* Zamiast wdrażać nowe obrazy kontenerów ECS w celu zmiany parametrów eventu w grze, włączenia nowego pakietu w sklepie czy aktywacji trybu awaryjnego (`DR_WARMUP_MODE`), korzystamy z **AWS AppConfig**:
* Kontenery ECS trzymają lokalnego agenta AppConfig (sidecar), który pobiera konfigurację w milisekundach z pamięci lokalnej.
* Wdrożenia konfiguracji przechodzą przez **automatyczne walidatory schematów JSON** i są wdrażane stopniowo (np. *Canary 10% przez 5 minut*) z automatycznym wycofaniem (*rollback*), jeśli wzrośnie wskaźnik błędów w CloudWatch.



---

### 8.5. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 8)

```hcl
locals {
  allowed_eu_regions = ["eu-central-1", "eu-west-1"]

  security_controls = {
    kms_multi_region       = true
    secrets_rotation_days  = 30
    waf_rate_limit_5min    = 3000 # Maks. 3000 żądań na 5 min z jednego IP (10 req/s)
    audit_retention_years  = 5
  }

  analytics_pipeline = {
    firehose_buffer_size_mb  = 64
    firehose_buffer_interval = 60 # sekundy
    storage_format           = "PARQUET"
    table_format             = "ICEBERG"
    s3_lifecycle_glacier_days = 180
  }

  appconfig_deployment = {
    growth_factor      = 20.0
    deployment_duration = 5  # minuty
    bake_time          = 5   # minuty na obserwację alarmów przed zatwierdzeniem
  }
}

```

---

## Sekcja 9: Observability, SRE i Zarządzanie Incydentami

### 9.1. Stos Obserwowalności (*Three Pillars* w skali 46,3k RPS)

Zamiast budować i utrzymywać własne klastry Elasticsearch/OpenSearch czy Prometheus (co pochłonęłoby czas kilku inżynierów), korzystamy z w pełni zarządzanych usług AWS opartych o otwarty standard **OpenTelemetry**:

1. **Metryki (ADOT Sidecar -> Amazon Managed Prometheus -> Amazon Managed Grafana):**
* Każde zadanie ECS Fargate uruchamia lekki kontener poboczny (**AWS Distro for OpenTelemetry — ADOT Collector**), który zbiera metryki aplikacji (opóźnienia p50/p95/p99, wskaźniki *Cache Hit Ratio* w Valkey, wielkość paczek SQS, czasy odpowiedzi Google Play API) i wysyła je strumieniowo do **AMP**.
* **Amazon Managed Grafana (AMG)** służy jako centralny ekran operacyjny (*Single Pane of Glass*) z gotowymi dashboardami dla każdego z 4 API, bazy Aurora oraz stanu budżetu błędów (SLI 99,5%).


2. **Rozproszone śledzenie zapytań (AWS X-Ray + Tail-Based Sampling):**
* Śledzenie każdego z 46 313 zapytań na sekundę zalałoby system logowania. Konfigurujemy kolektor ADOT w trybie **Tail-Based Sampling**:
* **100% śladów (Traces)** dla żądań zakończonych błędem (`HTTP 5xx`, `429`) lub przekraczających próg opóźnienia SLO (`> 150 ms` dla `/stats`, `> 400 ms` dla `/payments`).
* **0,5% śladów** dla poprawnych, szybkich żądań (`HTTP 200 OK`) jako linia bazowa.


* Dzięki temu w ciągu kilkunastu sekund SRE widzi dokładny *flamegraph* powolnego żądania (np. czy opóźnienie powstało w kontenerze ECS, na blokadzie w RDS Proxy, czy podczas oczekiwania na Google API).


3. **Logi strukturalne (JSON -> CloudWatch Logs + S3 Archival):**
* Kontenery wypisują logi wyłącznie w ustandaryzowanym formacie **JSON** zawierającym `trace_id`, `player_id` (zahashowane), `game_id` oraz `endpoint`.
* Logi operacyjne trzymamy w CloudWatch Logs przez **14 dni** (do szybkiego przeszukiwania przez *CloudWatch Logs Insights*), a następnie automatycznie eksportujemy do S3.



---

### 9.2. Alertowanie oparte o *SLO Burn Rate* (Zero szumu alarmowego)

Przy 22 Senior SRE najgorszym wrogiem jest *alert fatigue* (zmęczenie alarmami wywoływanymi przez chwilowe skoki CPU, które nie wpływają na graczy). **Zasada: budzimy człowieka w nocy (PagerDuty / Opsgenie) wyłącznie wtedy, gdy realnie zagrożony jest nasz budżet błędów SLI 99,5%.**

Stosujemy **Multi-Window, Multi-Burn-Rate Alerts** (zgodnie ze standardem Google SRE Workbook):

| Poziom Krytyczności | Współczynnik spalania (*Burn Rate*) | Okno pomiarowe (Długie / Krótkie) | Zużycie miesięcznego Error Budgetu | Akcja i kanał powiadomień |
| --- | --- | --- | --- | --- |
| **SEV-1 (Page / Telefon)** | **14,4x** | 1 godz. / 5 min | 2% budżetu w 1 godzinę (wyczerpanie w ~2 dni) | Natychmiastowe wybudzenie dyżurnego SRE (*On-Call*); przygotowanie procedury failoveru. |
| **SEV-2 (Page / Telefon)** | **6,0x** | 6 godz. / 30 min | 5% budżetu w 6 godzin (wyczerpanie w ~5 dni) | Pilna interwencja SRE; analiza degradacji bazy lub 3rd-party API. |
| **SEV-3 (Ticket / Slack)** | **1,0x – 3,0x** | 24 godz. / 2 godz. | Powolny wyciek budżetu | Brak budzenia w nocy; zgłoszenie na kanał zespołu przypisanego do danego API w godzinach pracy. |

*(Dodatkowo utrzymujemy tylko 3 twarde alarmy infrastrukturalne wyprzedzające awarię: zapełnienie puli IP w podsieci > 85%, wiek najstarszej wiadomości w kolejce SQS `/stats` > 60 s oraz opóźnienie replikacji Aurora Global Database > 30 s).*

---

### 9.3. Synthetic Monitoring (Testy Syntetyczne End-to-End)

Metryki wewnętrzne nie wykryją sytuacji, w której błąd konfiguracji WAF lub certyfikatu TLS na krawędzi odcina graczy z konkretnego kraju w Europie, zanim ruch w ogóle dotrze do naszego ALB.

* Uruchamiamy **Amazon CloudWatch Synthetics (Canaries)** z 4 europejskich lokalizacji (**Frankfurt, Irlandia, Paryż, Sztokholm**).
* Co **60 sekund** dedykowane boty testowe (na specjalnych kontach technicznych oznaczonych flagą `is_synthetic=true`, odfiltrowanych ze statystyk BI) wykonują pełną ścieżkę krytyczną dla każdego z 4 API oraz *Dienekes Plaza Web*:
1. Logowanie (`/auth`) i pobranie tokenu JWT.
2. Zapis i natychmiastowy odczyt paczki statystyk (`/stats`).
3. Symulacja zakupu testowego (`/payments` w trybie sandbox).


* Niepowodzenie w 2 lokalizacjach jednocześnie traktowane jest na równi z alarmem **SEV-1**.

---

### 9.4. Chaos Engineering i Regularne *GameDays* (AWS FIS)

Plany Disaster Recovery (RTO 15 min) i polityki *Circuit Breaker*, które nie są regularnie testowane pod obciążeniem, w dniu prawdziwej awarii nie zadziałają.

* **Ciągłe testy odporności (AWS Fault Injection Service — FIS):**
* W środowisku **Perf/Opt (1:1)** raz w tygodniu, a na **Produkcji** raz w miesiącu w godzinach niskiego ruchu (okno kontrolowane z dyżurnymi SRE), uruchamiamy automatyczne eksperymenty FIS:
* **Symulacja awarii Strefy Dostępności (AZ Blackhole):** odcięcie ruchu sieciowego w `eu-central-1a` na 15 minut i weryfikacja, czy ALB, ECS, Valkey i Aurora przejmują ruch w pozostałych 2 AZ bez utraty SLI 99,5%.
* **Failover instancji Writer w Aurorze:** wymuszenie przełączenia lidera bazy i pomiar czasu maskowania przerwy przez RDS Proxy (cel: < 3 s).
* **Awaria węzła ElastiCache (Valkey):** restart głównego sharda i weryfikacja odporności bazy na chwilowy wzrost *Cache Miss*.
* **Wstrzyknięcie opóźnień Google Play API (+5 s latency):** weryfikacja, czy Circuit Breaker poprawnie przełącza płatności w tryb asynchroniczny.




* **Kwartalne *GameDays*:** pełne ćwiczenie przełączenia między regionami (`eu-central-1` -> `eu-west-1`) z pomiarem stoperem rzeczywistego RTO (cel: poniżej 7 minut) i weryfikacją procedury rozgrzewania zimnego cache'u.

---

### 9.5. Wsadowe parametry dla Terraform / Gemini CLI (Sekcja 9)

```hcl
locals {
  observability_config = {
    adot_collector_image = "public.ecr.aws/aws-observability/aws-otel-collector:v0.41.0"
    xray_sampling = {
      error_rate       = 1.0   # 100% błędów 5xx/429 i przekroczeń SLO
      baseline_rate    = 0.005 # 0.5% poprawnych żądań
    }
    log_retention_days = 14
  }

  slo_burn_rate_alerts = {
    sev1_fast_burn = { burn_rate = 14.4, long_window_min = 60,  short_window_min = 5 }
    sev2_med_burn  = { burn_rate = 6.0,  long_window_min = 360, short_window_min = 30 }
    sev3_slow_burn = { burn_rate = 1.0,  long_window_min = 1440, short_window_min = 120 }
  }

  synthetics_locations = ["eu-central-1", "eu-west-1", "eu-west-3", "eu-north-1"]
}

```

---

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

---

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

---

## Sekcja 12: Pragmatyczne Kompromisy, Ryzyka i Ścieżka Ewolucji

### 12.1. Ochrona przed *Over-engineeringiem* (KISS i YAGNI w praktyce)

Nieograniczony budżet często kusi zespoły do budowania „architektury z konferencji”. Każda zbędna warstwa abstrakcji zwiększa jednak ryzyko błędu ludzkiego podczas incydentu. Poniżej znajdują się cztery świadome rezygnacje:

| Odrzucona technologia | Wybrana alternatywa | Uzasadnienie Principal Engineera |
| --- | --- | --- |
| **Amazon EKS (Kubernetes)** | **Amazon ECS na AWS Fargate** | Mamy do uruchomienia 13 bezstanowych usług HTTP/workerów. EKS wymagałby zarządzania aktualizacjami klastra, węzłami EC2, kontrolerami Ingress i CNI. Fargate zdejmuje ten narzut z zespołu i upraszcza izolację zadań. |
| **Multi-Region Active-Active SQL** | **Aurora Global Database (Warm Standby)** | Przy RPO 5 min i RTO 15 min rozproszony zapis między Frankfurtem a Irlandią nie ma uzasadnienia. Unikamy opóźnień konsensusu WAN (~22 ms na każdy zapis płatności) oraz konfliktów replikacji. |
| **Service Mesh (Istio / App Mesh)** | **ALB Path Routing + ECS Service Connect** | Nasze usługi nie tworzą głębokiego grafu mikroserwisów (komunikują się głównie z bazą, cachem i kolejką). Service Mesh dodałby narzut CPU/RAM i skomplikował debugowanie sieciowe. |
| **Własny klaster Kafka / Elasticsearch** | **SQS / Firehose + Managed Prometheus** | Utrzymanie Kafki i OpenSearch w skali 46,3k RPS wymagałoby dedykowanego zespołu do strojenia partycji i JVM. Usługi zarządzane skalują się bezobsługowo. |

---

### 12.2. Krytyczne Pułapki Operacyjne przy Skali 134M MAU

Nawet najlepiej zwymiarowana infrastruktura AWS może zostać unieruchomiona przez błędy na styku kodu aplikacji i baz danych. Oto 4 główne ryzyka i nasze zabezpieczenia:

1. **Blokujące migracje schematów SQL (*DDL Locks*):**
* *Ryzyko:* Wykonanie standardowego `ALTER TABLE` lub `CREATE INDEX` na tabeli liczącej 75 milionów wierszy w `aurora-api-1` zablokuje ruch zapisu i odczytu na kilka minut, niszcząc miesięczny budżet błędów SLI.
* *Mitygacja:* Wymuszamy w CI/CD ustawienie sesyjne `SET lock_timeout = '2s'` przed każdą migracją (jeśli baza nie zdobędzie blokady w 2 sekundy, migracja bezpiecznie przerywa działanie zamiast tworzyć kolejkę zablokowanych zapytań) oraz używamy wyłącznie `CREATE INDEX CONCURRENTLY`.


2. **Efekt kuli śnieżnej po przełączeniu DR (*Cold Cache Stampede*):**
* *Ryzyko:* Przełączenie ruchu na Irlandię (`eu-west-1`) z pustym klastrem Valkey wyśle 41,2k zapytań `/stats` na sekundę prosto do nowej bazy *Writer* Aurory.
* *Mitygacja:* Obowiązkowy mechanizm *Request Coalescing (Singleflight)* w kodzie API oraz 5-minutowa rampa otwierania ruchu `/stats` (30% -> 60% -> 100%) sterowana przez AWS AppConfig.


3. **Wyczerpanie limitów konta i adresów IP (*Silent Throttling*):**
* *Ryzyko:* Nagły skok graczy po premierze aktualizacji zatrzymuje się na domyślnych limitach konta AWS (np. liczba jednoczesnych zadań Fargate lub wyczerpane porty SNAT na NAT Gatewayu).
* *Mitygacja:* Sieci `/16` (IPAM), prywatne endpointy VPC dla wszystkich usług AWS (ruch wewnętrzny omija NAT Gatewaye) oraz zautomatyzowane podnoszenie *Service Quotas* w kodzie Terraform.


4. **Rozjazd zegarów systemowych (*Clock Skew*):**
* *Ryzyko:* Nasze zabezpieczenia przed *Replay Attacks* na `/stats` i `/payments` (okno ważności HMAC = 60 s) oraz krótkotrwałe tokeny JWT mogą odrzucać poprawne żądania, jeśli zegary kontenerów rozjadą się względem serwerów czasu.
* *Mitygacja:* Korzystamy z natywnej synchronizacji czasu **Amazon Time Sync Service** (precyzja mikrosekundowa) oraz dodajemy 10-sekundowy margines tolerancji (*clock skew leeway*) przy weryfikacji tokenów.



---

### 12.3. Mapa Drogowa Wdrożenia (8 Tygodni do Produkcji)

Dysponując 44 doświadczonymi inżynierami pracującymi równolegle w 6 zespołach (Sekcja 11), wdrażamy system w trzech kontrolowanych fazach:

* **Faza 1: Fundamenty, Sieć i Warstwa Danych (Tygodnie 1–3)**
* Utworzenie hierarchii kont w AWS Organizations, konfiguracja sieci VPC (`/16`), Global Accelerator, CloudFront oraz kluczy Multi-Region KMS.
* Uruchomienie klastrów Aurora Global Database, RDS Proxy, Valkey i DynamoDB Global Tables w środowiskach `Staging` oraz `Perf/Opt`.
* Zasilenie baz `Perf/Opt` syntetycznymi danymi (**134 miliony kont testowych**).


* **Faza 2: Warstwa Obliczeniowa, Testy 1:1 i *GameDay* DR (Tygodnie 4–6)**
* Wdrożenie wszystkich 13 serwisów ECS Fargate, potoków Canary (CodeDeploy) oraz stosu obserwowalności OpenTelemetry + Grafana.
* Przeprowadzenie pełnych testów obciążeniowych na **50 000 – 70 000 RPS** w środowisku `Perf/Opt`.
* Wykonanie pełnego ćwiczenia **Disaster Recovery GameDay** (symulacja awarii Frankfurtu, pomiar rzeczywistego RTO < 15 min i RPO < 5 min, weryfikacja rozgrzewania Valkey).


* **Faza 3: Migracja Produkcyjna i Utwardzanie do 99,95%+ (Tygodnie 7–8+)**
* Stopniowe przełączanie ruchu produkcyjnego gier (od najmniejszego *Theognis per Megara* na API #2, przez API #4 i #3, aż po *Pythodorus 3* na API #1) z wykorzystaniem wag w Global Acceleratorze (5% -> 25% -> 100%).
* Uruchomienie comiesięcznych testów **Chaos Engineering (AWS FIS)** na produkcji oraz optymalizacja zapytań analitycznych w hurtowni S3 Iceberg / Athena.



---

### 12.4. Gotowy Wsadowy Prompt dla Gemini CLI (Generowanie Repozytorium IaC)

Mamy już kompletny, spójny matematycznie model całej infrastruktury. Poniższy blok możesz skopiować i wkleić bezpośrednio do **Gemini CLI** w katalogu docelowym projektu, aby wygenerować szkielet repozytorium OpenTofu/Terraform zgodny ze wszystkimi decyzjami z Sekcji 1–12:

```text
Działaj jako Principal Cloud Architect. Wygeneruj kompletne, produkcyjne repozytorium OpenTofu / Terraform (v1.8+) dla wieloregionowej architektury AWS (Primary: eu-central-1, DR: eu-west-1) obsługującej ekosystem 6 gier (134M MAU, 46 313 Peak RPS, SLI >= 99.5%, RPO <= 5 min, RTO <= 15 min).

Wymagana struktura katalogów (izolowane warstwy stanu):
1. modules/
   - network-vpc/ (VPC /16, 3 AZ, Public/Private/Isolated subnets, NAT Gateways z wieloma EIP, VPC Interface & Gateway Endpoints)
   - edge-routing/ (AWS Global Accelerator z Anycast IP, Route 53 ARC Routing Controls, CloudFront + S3 dla Web, AWS WAF z rate-limitingiem)
   - data-aurora-global/ (Aurora Global Database PostgreSQL 16 i MySQL 8.0, instancje Graviton db.r8g, aurora-iopt1, Backtrack, RDS Proxy RW/RO)
   - data-valkey-dynamodb/ (ElastiCache Valkey Cluster Mode Enabled Multi-AZ, DynamoDB Global Tables On-Demand z TTL, kolejki SQS + DLQ)
   - compute-ecs-fargate/ (Klastry ECS, zadania Fargate ARM64 2vCPU/4GB, ALB Path-Based Routing dla /v1/stats/*, /v1/auth/*, /v1/payments/*, CodeDeploy Canary 10% 5m, Scheduled + Target Tracking Autoscaling)
   - observability-security/ (KMS Multi-Region CMK, Secrets Manager rotacja 30d, IAM Least Privilege Task Roles, CloudWatch Synthetics, alarmy SLO Multi-Window Burn Rate)
2. environments/
   - shared-services/
   - dev/ (scale_factor = 0.05, Single-Region, Aurora Serverless v2)
   - staging/ (scale_factor = 0.15, Multi-Region DR)
   - perf-opt/ (scale_factor = 1.00, 1:1 Prod Parity, Multi-Region DR)
   - prod/ (scale_factor = 1.00, Multi-Region DR)

Zastosuj następujące dokładne parametry wymiarowania dla Prod i Perf/Opt:
- API #1 (Pythodorus 3, 24 188 RPS): Aurora PG (Primary: db.r8g.16xlarge, 2x Reader: db.r8g.12xlarge, DR: db.r8g.16xlarge), Valkey (6 shardów x 2 repliki cache.r7g.2xlarge), ECS (stats: min 24/max 90, auth: min 6/max 15, payments: min 6/max 12).
- API #2 (Theognis per Megara, 750 RPS): Aurora PG (Primary: db.r8g.xlarge, 1x Reader: db.r8g.xlarge, DR: db.r8g.xlarge), Valkey (1 shard x 2 repliki cache.r7g.large), ECS (stats: min 3/max 8, auth: min 3/max 6, payments: min 3/max 6).
- API #3 (Agrippa Mosa 1+2, 17 250 RPS): Aurora PG (Primary: db.r8g.12xlarge, 2x Reader: db.r8g.8xlarge, DR: db.r8g.12xlarge), Valkey (4 shardy x 2 repliki cache.r7g.2xlarge), ECS (stats: min 18/max 65, auth: min 6/max 12, payments: min 6/max 10).
- API #4 (Dienekes Plaza App+Web, 4 125 RPS): Aurora MySQL (Primary: db.r8g.4xlarge, 1x Reader: db.r8g.4xlarge, DR: db.r8g.4xlarge), Valkey (2 shardy x 2 repliki cache.r7g.xlarge), ECS (stats: min 6/max 20, auth: min 3/max 8, payments: min 3/max 6).
- Web Dienekes Plaza (375 RPS): ECS Fargate (min 6/max 15) za CloudFront + ALB.

Zadbaj o pełne tagowanie zasobów, szyfrowanie KMS wszędzie, brak hardcoded sekretów oraz dodaj plik Makefile do uruchamiania `tofu fmt`, `tofu validate`, `tflint` i `checkov`.

```
