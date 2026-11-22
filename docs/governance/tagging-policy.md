# Cloud Governance: Polityka Tagowania Zasobów (Tagging Policy)

## 1. Cel i Egzekwowanie
Każdy zasób tworzony w AWS musi posiadać komplet tagów umożliwiających przypisanie odpowiedzialności zespołowej (44 inżynierów w 6 squadach), filtrowanie dashboardów w Grafanie oraz egzekwowanie polityk bezpieczeństwa i RODO.

* **Egzekwowanie w CI/CD:** Narzędzie **Checkov** blokuje Pull Requesty Terraform pozbawione wymaganych tagów.
* **Egzekwowanie w AWS:** **AWS Organizations Tag Policies** blokują tworzenie zasobów bez poprawnych wartości tagów na poziomie konta.
* **Propagacja w Terraform:** Wszystkie tagi globalne są definiowane w bloku `default_tags` dostawcy `provider "aws"`.

---

## 2. Obowiązkowe Klucze Tagów (*Mandatory Tags*)

| Klucz Tagu | Format / Dozwolone Wartości | Opis i Przeznaczenie | Przykład |
| :--- | :--- | :--- | :--- |
| **`Environment`** | `shared` \| `audit` \| `dev` \| `staging` \| `perf-opt` \| `load-gen` \| `prod` | Określa cykl życia i poziom izolacji zasobu. | `prod` |
| **`ServiceDomain`** | `api-1` \| `api-2` \| `api-3` \| `api-4` \| `web-dienekes` \| `platform` \| `analytics` | Przypisuje zasób do konkretnego API, gry lub warstwy współdzielonej. | `api-1` |
| **`ServicePath`** | `stats` \| `auth` \| `payments` \| `frontend` \| `shared` | Identyfikuje krytyczność ścieżki biznesowej (powiązane z SLO). | `payments` |
| **`OwnerSquad`** | `core-platform` \| `data-reliability` \| `cicd-devex` \| `observability-sre` \| `squad-core-hits` \| `squad-growth-web` | Wskazuje jeden z 6 zespołów inżynieryjnych odpowiedzialnych za incydenty. | `squad-core-hits` |
| **`DataClassification`** | `public` \| `internal` \| `confidential` \| `pii-gdpr` | Określa wymagania szyfrowania KMS i procedurę usuwania RODO. | `pii-gdpr` |
| **`BackupTier`** | `critical-dr` \| `standard` \| `ephemeral-none` | Steruje politykami AWS Backup, PITR oraz skryptami parkowania `perf-opt`. | `critical-dr` |
| **`ManagedBy`** | `opentofu` \| `terraform` | Gwarantuje, że zasób jest zarządzany wyłącznie przez kod IaC. | `opentofu` |
| **`StateLayer`** | `00-foundation` \| `01-network-edge` \| `02-data-stateful` \| `03-compute-apps` | Ułatwia szybkie namierzenie pliku stanu Terraform podczas incydentu. | `02-data-stateful` |

---

## 3. Reguły Nazewnictwa Zasobów (Naming Convention)
Wszystkie zasoby AWS stosują jednolity wzorzec nazewnictwa:
`{project}-{env}-{region_short}-{domain}-{resource_type}-{suffix}`

* `project`: `gm` (Gaming Platform)
* `region_short`: `euc1` (`eu-central-1`), `euw1` (`eu-west-1`)
* **Przykłady:**
  * Klaster ECS: `gm-prod-euc1-api1-ecs`
  * Baza Aurora: `gm-prod-euc1-api1-aurora-pg`
  * Kolejka SQS: `gm-prod-euc1-api1-stats-queue`