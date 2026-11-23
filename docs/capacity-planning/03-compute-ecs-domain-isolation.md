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
