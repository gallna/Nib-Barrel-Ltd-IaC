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
