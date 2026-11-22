# Low-Level Design (LLD): Kontrakty Modułów Terraform / OpenTofu

## 1. Architektura Warstw Stanu i Przepływ Danych
Repozytorium dzieli infrastrukturę na **4 niezależne warstwy stanu (*State Layers*)**. Warstwy wyższe odczytują dane z warstw niższych wyłącznie przez blok `data "terraform_remote_state"` (S3 Backend z blokadą DynamoDB), co eliminuje cykliczne zależności.

```text
[ 00-foundation ] ---> [ 01-network-edge ] ---> [ 02-data-stateful ] ---> [ 03-compute-apps ]
  (KMS, IAM, Org)       (VPC, AGA, WAF)         (Aurora, Valkey, SQS)     (ECS, ALB, Alarms)

```

---

## 2. Specyfikacja Interfejsów Modułów (`modules/`)

### 2.1. `modules/network-vpc`

Tworzy izolowane VPC `/16` w 3 strefach dostępności wraz z NAT Gatewayami i endpointami AWS PrivateLink.

* **Inputs (`variables.tf`):**
* `environment` (`string`) — nazwa środowiska (`prod`, `perf-opt`, itd.)
* `vpc_name` (`string`) — np. `core-gaming`
* `vpc_cidr` (`string`) — np. `10.10.0.0/16`
* `azs` (`list(string)`) — lista 3 stref dostępności
* `nat_eip_count_per_az` (`number`, default: `2`) — liczba EIP per NAT Gateway (ochrona SNAT)
* `interface_endpoints` (`list(string)`) — lista usług AWS PrivateLink


* **Outputs (`outputs.tf`):**
* `vpc_id` (`string`)
* `public_subnet_ids` (`list(string)`)
* `private_app_subnet_ids` (`list(string)`)
* `isolated_data_subnet_ids` (`list(string)`)
* `vpc_endpoints_sg_id` (`string`)



---

### 2.2. `modules/edge-routing`

Konfiguruje AWS Global Accelerator, Route 53 ARC, CloudFront (dla Web) oraz AWS WAF.

* **Inputs (`variables.tf`):**
* `environment` (`string`)
* `primary_alb_arns` (`map(string)`) — mapa `api_1..api_4, web` -> ARN ALB w `eu-central-1`
* `dr_alb_arns` (`map(string)`) — mapa `api_1..api_4, web` -> ARN ALB w `eu-west-1`
* `waf_rate_limit_5min` (`number`, default: `3000`)
* `web_static_bucket_domain` (`string`)


* **Outputs (`outputs.tf`):**
* `global_accelerator_ips` (`map(list(string))`) — statyczne adresy Anycast IP per API
* `arc_routing_control_arns` (`map(string)`) — ARN przełączników failoveru DR
* `cloudfront_distribution_domain` (`string`)
* `waf_web_acl_arn` (`string`)



---

### 2.3. `modules/data-aurora-global`

Tworzy klaster Amazon Aurora Global Database (PostgreSQL 16 lub MySQL 8.0), instancje Graviton, tryb I/O-Optimized oraz Amazon RDS Proxy.

* **Inputs (`variables.tf`):**
* `api_key` (`string`) — `api_1`..`api_4`
* `engine` (`string`) — `aurora-postgresql` lub `aurora-mysql`
* `engine_version` (`string`)
* `primary_instance_class` (`string`) — np. `db.r8g.16xlarge`
* `reader_instance_class` (`string`)
* `reader_count` (`number`)
* `dr_instance_class` (`string`)
* `primary_subnet_ids` (`list(string)`) — `isolated_data_subnet_ids` z `eu-central-1`
* `dr_subnet_ids` (`list(string)`) — `isolated_data_subnet_ids` z `eu-west-1`
* `kms_key_arn` (`string`) — klucz Multi-Region KMS


* **Outputs (`outputs.tf`):**
* `global_cluster_id` (`string`)
* `primary_rds_proxy_rw_endpoint` (`string`)
* `primary_rds_proxy_ro_endpoint` (`string`)
* `dr_rds_proxy_rw_endpoint` (`string`)
* `dr_rds_proxy_ro_endpoint` (`string`)
* `db_secret_arn` (`string`)
* `db_security_group_id` (`string`)



---

### 2.4. `modules/data-valkey-dynamodb`

Tworzy klaster ElastiCache (Valkey Cluster Mode Enabled), DynamoDB Global Tables dla `/auth` oraz kolejki SQS (+ DLQ) dla `/stats` i rekoncyliacji płatności.

* **Inputs (`variables.tf`):**
* `api_key` (`string`)
* `valkey_node_type` (`string`)
* `valkey_shards` (`number`)
* `valkey_replicas_per_shard` (`number`)
* `subnet_ids` (`list(string)`) — `isolated_data_subnet_ids`
* `kms_key_arn` (`string`)
* `create_auth_global_table` (`bool`, default: `false`) — tworzone raz dla wspólnej warstwy auth


* **Outputs (`outputs.tf`):**
* `valkey_configuration_endpoint` (`string`)
* `valkey_security_group_id` (`string`)
* `stats_sqs_queue_url` (`string`)
* `stats_sqs_queue_arn` (`string`)
* `payments_reconciliation_queue_url` (`string`)
* `dynamodb_auth_table_name` (`string`)



---

### 2.5. `modules/compute-ecs-fargate`

Tworzy klaster ECS, ALB z routingiem po ścieżkach (`/v1/stats/*`, `/v1/auth/*`, `/v1/payments/*`), izolowane serwisy Fargate ARM64, polityki autoskalowania oraz grupy wdrożeniowe CodeDeploy Canary.

* **Inputs (`variables.tf`):**
* `cluster_name` (`string`)
* `vpc_id` (`string`)
* `public_subnet_ids` (`list(string)`) — dla ALB
* `private_subnet_ids` (`list(string)`) — dla zadań Fargate
* `services_config` (`map(object({ cpu = number, memory = number, min = number, max = number, rps_target = number, path = string }))`)
* `container_image_uri` (`string`)
* `environment_variables` (`map(string)`) — endpointy RDS Proxy, Valkey, SQS
* `waf_web_acl_arn` (`string`)
* `enable_canary_deployment` (`bool`)


* **Outputs (`outputs.tf`):**
* `ecs_cluster_arn` (`string`)
* `alb_arn` (`string`)
* `alb_dns_name` (`string`)
* `ecs_tasks_security_group_id` (`string`)
* `service_arns` (`map(string)`)



---

### 2.6. `modules/observability-security`

Konfiguruje klucze Multi-Region KMS, alarmy SLO Multi-Window Burn Rate, testy syntetyczne CloudWatch Synthetics oraz eksperymenty Chaos Engineering (AWS FIS).

* **Inputs (`variables.tf`):**
* `environment` (`string`)
* `alb_arn_suffixes` (`map(string)`)
* `slo_targets` (`object({ payments = number, auth = number, stats = number })`)
* `pagerduty_sns_topic_arn` (`string`)
* `enable_chaos_experiments` (`bool`)


* **Outputs (`outputs.tf`):**
* `kms_multi_region_key_arn` (`string`)
* `slo_alarm_arns` (`map(string)`)
* `synthetics_canary_names` (`list(string)`)


