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
