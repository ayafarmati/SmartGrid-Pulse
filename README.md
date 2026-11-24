# SmartGrid Pulse

Projet d’Aya Farmati et d’Abarkha pour la prévision de la demande électrique et la supervision de cinq sous-stations simulées sur Google Cloud.

La chaîne **Cloud Run → Pub/Sub → BigQuery Bronze → Silver → Gold → Data Studio** et l’archivage **Pub/Sub → Cloud Storage** ont été validés sur GCP en `europe-west1`. Le rapport a affiché cinq stations, dont Madrid à `49.7 Hz`. La DLQ a été testée dans un scénario isolé. Un batch Dataproc a vérifié la lecture de Cloud Storage et de BigQuery Gold. `Dim_Date`, `Dim_Time` et `Fact_Energy_Load` existent en Gold et attendent leur chargement.

[Guide de la pipeline et de LookML](guide-pipeline.html) · [Schéma d’avancement du binôme](architecture-smartgrid-pulse-looker.png)

## Reprendre en binôme

| Responsable | Prochain chantier |
| --- | --- |
| Aya Farmati | Calendrier et fait de charge en Gold, contrôles qualité, variables de prévision, modèle Spark et restitution de la charge prévue. |
| Abarkha | Fichiers historiques dans Bronze, ETL PySpark et météo, `Dim_City` et `Fact_Weather_Obs` en Gold, anomalies, supervision et orchestration. |

Le premier élément à transmettre à Aya est un extrait de charge nettoyé, avec une ligne nationale par heure UTC et les mesures en MW. Le guide détaille les connexions existantes et l’architecture cible, dont Looker et LookML. L’intégration à une instance Looker reste à tester.

Pour travailler, pars d’une branche issue de `main`. Le projet GCP déployé utilise l’état Terraform conservé dans le dossier Cloud Shell d’origine. Pour appliquer des changements à ce même projet, convenez ensemble du dossier d’exécution et relisez le nouveau plan. Un clone du dépôt suffit pour modifier le code et lancer les validations locales.

## Structure du code

- `terraform/` contient les API, Cloud Run, Pub/Sub, les règles d’accès, les destinations Bronze, les vues Silver et Gold et les tables métier Gold.
- `simulator/telemetry.py` génère les relevés normaux et les scénarios d’alerte. `simulator/app.py` les publie dans Pub/Sub depuis Cloud Run.
- `scripts/` contient les tests de la DLQ et des lectures depuis Dataproc.
- `sql/` contient le script d’initialisation du calendrier Gold.

Pub/Sub conserve le corps brut du message avec son identifiant et son heure de publication. En développement, les partitions BigQuery expirent après sept jours.

## Valider Terraform localement

Installe [Terraform](https://developer.hashicorp.com/terraform/install) (version 1.5 ou supérieure) et [Google Cloud CLI](https://docs.cloud.google.com/sdk/docs/install-sdk), puis ouvre un terminal à la racine du dépôt.

```powershell
cd terraform
terraform fmt -check
terraform init
terraform validate
```

`terraform init` télécharge les providers et crée `.terraform.lock.hcl`. Ces commandes ne créent aucune ressource GCP. Versionne le fichier de verrouillage après l’initialisation.

Depuis Cloud Shell, utilise la même procédure. Si tu as installé le binaire dans `~/.local/bin`, remplace `terraform` par `"$HOME/.local/bin/terraform"`. Pour reprendre un déploiement existant, travaille dans le dossier Cloud Shell qui contient déjà son fichier d’état.

## Préparer un plan de développement

Utilise un projet GCP de développement avec facturation active et les droits de gestion des API, de Pub/Sub, de BigQuery et de l’IAM de la table. Vérifie les alertes de budget dans la console de facturation.

Sur un projet neuf, active d’abord l’API Cloud Resource Manager. Son absence peut bloquer le provisionnement de Pub/Sub avec une erreur `403 SERVICE_DISABLED`.

```powershell
gcloud auth login
gcloud projects list
$env:TF_VAR_project_id = Read-Host 'Identifiant du projet GCP de développement'
gcloud projects describe $env:TF_VAR_project_id
gcloud services enable cloudresourcemanager.googleapis.com --project=$env:TF_VAR_project_id
gcloud auth application-default login
terraform plan -out=smartgrid-dev.tfplan
```

Vérifie l’identifiant du projet, la région et les ressources dans le plan avant de lancer `terraform apply smartgrid-dev.tfplan`. L’application crée un topic, une souscription, un dataset, une table et les droits associés. La [souscription directe BigQuery](https://cloud.google.com/pubsub/pricing#throughput_costs) est facturée au débit.

Si une application échoue après avoir créé des ressources, conserve le fichier d’état. Corrige l’erreur, puis génère un nouveau plan depuis le même dossier avant de reprendre l’application.

## Vérifier le flux après le déploiement

```powershell
$smartGridTopic = terraform output -raw telemetry_topic
gcloud pubsub topics publish $smartGridTopic --project=$env:TF_VAR_project_id --message='smartgrid-smoke-test'
```

Dans BigQuery Studio, remplace `PROJECT_ID` par l’identifiant de ton projet. Une fois le message livré, la requête doit afficher `smartgrid-smoke-test` et son identifiant.

```sql
SELECT message_id, publish_time, SAFE_CONVERT_BYTES_TO_STRING(data) AS message
FROM `PROJECT_ID.bronze_smartgrid.streaming_raw_events`
WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
  AND SAFE_CONVERT_BYTES_TO_STRING(data) = 'smartgrid-smoke-test'
ORDER BY publish_time DESC
LIMIT 10;
```

## Tester le simulateur localement

Depuis la racine `smartgrid-pulse`, lance le simulateur Python. Chaque commande imprime cinq lignes JSON, une par sous-station.

```powershell
python .\simulator\telemetry.py
python .\simulator\telemetry.py --scenario sous-frequence
```

Le second test doit afficher un événement `UNDER_FREQUENCY` à `49.7 Hz` pour Madrid, et quatre événements `NORMAL`. Les scénarios `surfrequence`, `surtension` et `surchauffe` sont également disponibles. Le test local ne consomme aucune ressource GCP.

## Déployer le simulateur Cloud Run depuis Cloud Shell

Le service `smartgrid-simulator` exige une identité autorisée. Chaque requête `POST /simulate` publie un seul lot de cinq relevés et renvoie le `batch_id`, les identifiants de publication et les stations confirmées. Le compte du service a le rôle de publication sur le seul topic du projet.

### 1. Créer le dépôt d’images et préparer les permissions

Pour reprendre le projet `smartgrid-pulse`, copie `terraform/cloudrun.tf` dans le dossier Cloud Shell qui contient déjà `terraform.tfstate` et copie les fichiers `simulator/` dans le dossier `simulator` au même niveau que `terraform`. Le plan et l’état existants restent dans Cloud Shell.

```bash
cd ~/smartgrid-pulse/terraform
export TF_VAR_project_id=smartgrid-pulse
tf="$HOME/.local/bin/terraform"
"$tf" validate
"$tf" plan -out=smartgrid-registry.tfplan
```

Sur le socle déjà validé, ce plan ajoute trois API (Artifact Registry, IAM et Cloud Run), le dépôt Docker, le compte de service et sa permission Pub/Sub. Le service Cloud Run sera créé à l’étape 3. Vérifie la liste des changements, puis applique le plan.

```bash
"$tf" apply smartgrid-registry.tfplan
```

### 2. Construire et pousser une image de test

```bash
repo_uri=$("$tf" output -raw simulator_repository)
image_uri="$repo_uri/simulator:v0.1.0"
gcloud auth configure-docker "${repo_uri%%/*}"
docker build --platform linux/amd64 -t "$image_uri" ../simulator &&
docker push "$image_uri"
```

### 3. Créer le service authentifié

Récupère le digest de l’image, puis conserve-le dans un fichier de variables local avec l’identité Google qui déclenchera les tests. Utilise l’adresse de ton compte utilisateur actif.

```bash
image_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image_uri") &&
invoker_email=$(gcloud config get-value account) &&
test -n "$image_digest" && test -n "$invoker_email" &&
printf 'simulator_image = "%s"\nsimulator_invoker_member = "user:%s"\n' \
  "$image_digest" "$invoker_email" > simulator.auto.tfvars

"$tf" plan -out=smartgrid-cloudrun.tfplan
```

Le plan doit ajouter le service et le droit d’invocation pour l’identité choisie. Après vérification, applique le plan. Le service est configuré pour descendre à zéro instance au repos et plafonner à une instance.

```bash
"$tf" apply smartgrid-cloudrun.tfplan
```

### 4. Déclencher un lot et le vérifier dans BigQuery

```bash
service_url=$("$tf" output -raw simulator_url)
curl -sS --fail-with-body "$service_url/simulate" \
  -H "Authorization: Bearer $(gcloud auth print-identity-token)" \
  -H 'Content-Type: application/json' \
  -d '{"scenario":"sous-frequence"}' | tee smartgrid-batch.json
```

La réponse attendue contient cinq publications confirmées et une seule alerte, à Madrid. Si le service retourne `Publication incomplete`, le `batch_id` et les confirmations déjà reçues permettent de retrouver les publications de cette tentative. Un nouvel appel crée son propre lot.

```bash
batch_id=$(jq -er 'select(.error | not) | .batch_id' smartgrid-batch.json) &&
bq --project_id=smartgrid-pulse --location=europe-west1 query \
  --use_legacy_sql=false --maximum_bytes_billed=104857600 \
  --parameter="batch_id:STRING:$batch_id" <<'SQL'
WITH events AS (
  SELECT SAFE_CONVERT_BYTES_TO_STRING(data) AS payload, publish_time
  FROM `smartgrid-pulse.bronze_smartgrid.streaming_raw_events`
  WHERE publish_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
    AND JSON_VALUE(attributes, '$.batch_id') = @batch_id
)
SELECT
  JSON_VALUE(payload, '$.device_id') AS device_id,
  JSON_VALUE(payload, '$.grid_status') AS grid_status,
  SAFE_CAST(JSON_VALUE(payload, '$.metrics.frequency_hz') AS FLOAT64) AS frequency_hz
FROM events
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY JSON_VALUE(payload, '$.event_id') ORDER BY publish_time DESC
) = 1
ORDER BY device_id;
SQL
```

Attends la livraison des cinq lignes, dont `SUB-MADRID-01` à `49.7 Hz` avec le statut `UNDER_FREQUENCY`.

## Archiver les relevés Pub/Sub dans Cloud Storage

Le fichier `terraform/archive.tf` ajoute l’API Storage, un bucket Bronze privé, les droits d’écriture de l’agent Pub/Sub et la souscription `grid-telemetry-archive-sub`. La souscription BigQuery reçoit toujours les mêmes publications.

### 1. Préparer et vérifier le plan

Importe `archive.tf` dans le dossier Terraform existant de Cloud Shell. Conserve `terraform.tfstate` et `simulator.auto.tfvars` pour que Terraform reprenne le projet et garde le simulateur déployé.

```bash
cd ~/smartgrid-pulse/terraform
export TF_VAR_project_id=smartgrid-pulse
tf="$HOME/.local/bin/terraform"
"$tf" validate && "$tf" plan -out=smartgrid-archive.tfplan
```

Vérifie que le plan contient cinq ajouts, avec zéro modification et zéro suppression. Applique le plan relu avec `"$tf" apply smartgrid-archive.tfplan`.

### 2. Vérifier un nouveau lot

Déclenche un nouveau lot avec la commande Cloud Run de la section précédente. Chaque publication envoyée après la création de la souscription peut être exportée dans Cloud Storage. Pub/Sub regroupe les messages et finalise normalement les objets après environ une minute. Un lot peut être réparti sur plusieurs objets.

```bash
archive_uri=$("$tf" output -raw telemetry_archive_uri)
gcloud storage ls --recursive "$archive_uri"
```

Les fichiers se trouvent sous `iot/AAAA/MM/JJ/HH/` en UTC. Inspecte les nouveaux objets avec `gcloud storage cat 'gs://…/fichier.ndjson'` et vérifie le `batch_id` commun aux cinq événements. On archive ici le contenu JSON du message. Les identifiants attribués par Pub/Sub restent disponibles dans BigQuery. [Export Pub/Sub vers Cloud Storage](https://docs.cloud.google.com/pubsub/docs/create-cloudstorage-subscription)

Les règles de cycle de vie s’appliquent uniquement au préfixe `iot/`. Les archives passent en Nearline à J+30 et deviennent éligibles à la suppression à J+90. Après suppression, la période de récupération par défaut de Cloud Storage s’applique. Le futur préfixe `historical/` est hors de ces règles. [Cycle de vie Cloud Storage](https://docs.cloud.google.com/storage/docs/lifecycle)

Le délai d’acquittement de la souscription Terraform correspond au réglage observé sur GCP. Il est de 60 secondes, comme la durée de regroupement des fichiers.

Recette GCP validée avec le lot `f9d2a046-aa0b-42d2-bc71-e79c830f3d7e`. Les archives ont restitué cinq stations distinctes. Madrid a affiché `UNDER_FREQUENCY` à `49.7 Hz` et les quatre autres `NORMAL`.

## Préparer la file de quarantaine Pub/Sub

Le topic `grid-telemetry-dlq` recueille les échecs de livraison des souscriptions BigQuery et Cloud Storage. Pub/Sub tente de rediriger le message après environ cinq tentatives. Il conserve le message d’origine et ajoute des informations sur la souscription source. La souscription de lecture `grid-telemetry-dlq-sub` conserve les messages non acquittés pendant sept jours. [Fonctionnement de la DLQ Pub/Sub](https://docs.cloud.google.com/pubsub/docs/dead-letter-topics)

### 1. Préparer le plan

Transfère la mise à jour de `terraform/pubsub.tf`, `terraform/archive.tf` et `terraform/dlq.tf` dans le dossier Cloud Shell existant. Si tu utilises le fichier `smartgrid-pubsub-dlq.patch`, importe-le dans ton dossier personnel Cloud Shell et exécute les commandes suivantes. `git apply --check` vérifie la compatibilité du patch avec les fichiers existants avant de les modifier. L’état et les variables du service Cloud Run restent dans le dossier Terraform.

```bash
cd ~/smartgrid-pulse &&
git apply --check ~/smartgrid-pubsub-dlq.patch &&
git apply ~/smartgrid-pubsub-dlq.patch &&
cd terraform &&
export TF_VAR_project_id=smartgrid-pulse &&
tf="$HOME/.local/bin/terraform" &&
"$tf" validate &&
"$tf" plan -out=smartgrid-dlq.tfplan
```

Le plan attendu affiche cinq ajouts, deux modifications sur place et zéro suppression. Les ajouts sont le topic DLQ, sa souscription de lecture et les trois permissions de transfert pour l’agent Pub/Sub. Les deux modifications ajoutent `dead_letter_policy` aux souscriptions de livraison existantes. Applique le plan après vérification.

### 2. Vérifier la configuration et le transfert

```bash
for sub in grid-telemetry-bigquery-sub grid-telemetry-archive-sub; do
  gcloud pubsub subscriptions describe "$sub" --project=smartgrid-pulse \
    --format='yaml(name,deadLetterPolicy)'
done
```

Les deux souscriptions doivent afficher la même destination `grid-telemetry-dlq` et `maxDeliveryAttempts: 5`. Vérifie ensuite qu’un nouveau lot de cinq relevés continue d’arriver dans BigQuery et Cloud Storage.

Pour vérifier le transfert, importe `scripts/verify_dlq.py` dans ton dossier personnel Cloud Shell et lance le test isolé. Il utilise Python et le compte actif de `gcloud`.

```bash
python3 ~/verify_dlq.py --project smartgrid-pulse
```

Le script crée un topic et deux souscriptions de recette dont les noms commencent par `grid-dlq-test-`. Il publie un seul message synthétique, refuse les tentatives sur sa souscription source et recherche le transfert dans une souscription filtrée du topic DLQ existant. Attends la ligne `DLQ OK`, qui indique l’identifiant redirigé, sa source et le nombre de tentatives observées. Les trois ressources de recette sont supprimées à la fin du test. La souscription de lecture de la DLQ du projet peut conserver le message synthétique pendant sa rétention normale.

Le contrôle porte sur un échec de livraison. Une sous-fréquence valide reste un relevé à livrer vers BigQuery et GCS. [Permissions et suivi des tentatives](https://docs.cloud.google.com/pubsub/docs/dead-letter-topics#grant_the_iam_roles_to_use_dead-letter_topics)

Recette GCP réussie. Le message de test `23334649635548754` a été refusé cinq fois. Pub/Sub l’a redirigé sous l’identifiant `23335816191888499` depuis `grid-dlq-test-a0551dd212fd-source`.

## Préparer la télémétrie Silver dans BigQuery

`terraform/silver.tf` crée le dataset `silver_smartgrid` et la vue `telemetry_clean`. La vue lit sept jours de partitions Bronze, décode le JSON, type les mesures, contrôle les champs obligatoires et conserve le relevé valide le plus récent par `event_id`. Les fréquences entre 49 et 51 Hz et les tensions entre 360 et 440 kV sont admises. Le scénario de Madrid à 49,7 Hz reste visible avec son statut d’alerte.

La vue vise la télémétrie structurée du simulateur. Les messages de test manuels incomplets restent consultables dans la table Bronze. Une vue logique réutilise les données sans les stocker une seconde fois. [Vues logiques BigQuery](https://docs.cloud.google.com/bigquery/docs/views)

### 1. Préparer le plan

Importe `terraform/silver.tf` dans le dossier Terraform Cloud Shell existant. Le plan doit afficher deux ajouts, zéro modification et zéro suppression.

```bash
cd ~/smartgrid-pulse/terraform
export TF_VAR_project_id=smartgrid-pulse
tf="$HOME/.local/bin/terraform"
"$tf" validate && "$tf" plan -out=smartgrid-silver.tfplan
```

Avant l’application, valide le SQL avec BigQuery en mode `dry_run`. La requête lit seulement la table Bronze déjà disponible.

```bash
"$tf" show -json smartgrid-silver.tfplan |
  jq -er '.planned_values.root_module.resources[]
    | select(.address == "google_bigquery_table.telemetry_clean")
    | .values.view[0].query' |
  bq --project_id=smartgrid-pulse --location=europe-west1 query \
    --use_legacy_sql=false --dry_run
```

### 2. Vérifier un lot dans Silver

Après l’application du plan, déclenche le simulateur ou utilise un lot déjà présent dans les partitions Bronze. Remplace l’exemple de `batch_id` par l’identifiant du lot à vérifier.

```bash
bq --project_id=smartgrid-pulse --location=europe-west1 query \
  --use_legacy_sql=false --maximum_bytes_billed=104857600 \
  --parameter='batch_id:STRING:f9d2a046-aa0b-42d2-bc71-e79c830f3d7e' <<'SQL'
SELECT device_id, frequency_hz, voltage_kv, grid_status, is_alert
FROM `smartgrid-pulse.silver_smartgrid.telemetry_clean`
WHERE batch_id = @batch_id
ORDER BY device_id;
SQL
```

La vue doit renvoyer cinq stations. Madrid doit afficher `49.7`, `UNDER_FREQUENCY` et `true`. Cette vue traite les mesures IoT. Les faits historiques de charge et de météo seront chargés avec leurs grains respectifs lorsque les sources historiques seront prêtes.

Recette GCP validée sur le lot `31dc8a2b-5392-47ce-b51f-2fd7b917af8f`. La vue renvoie une ligne par station, avec la fréquence et la tension numériques. Madrid est seule en alerte à `49.7 Hz`.

## Relier la télémétrie Silver à la supervision

`terraform/gold_telemetry.tf` crée la vue `gold_smartgrid.telemetry_latest`. Elle lit `silver_smartgrid.telemetry_clean` et retourne le relevé le plus récent disponible par station, avec la fréquence, la tension, la température et le statut. Elle hérite de la fenêtre de sept jours de Silver. Une période sans télémétrie peut donc donner un résultat vide.

Après transfert de `gold_telemetry.tf` dans le dossier personnel de Cloud Shell, crée le plan depuis le dossier Terraform déjà déployé.

```bash
cd ~/smartgrid-pulse/terraform &&
cp ~/gold_telemetry.tf . &&
export TF_VAR_project_id=smartgrid-pulse &&
"$HOME/.local/bin/terraform" validate &&
"$HOME/.local/bin/terraform" plan -out=smartgrid-supervision.tfplan
```

Le plan attendu ajoute uniquement `google_bigquery_table.telemetry_latest`. Après l’application, vérifie la lecture de la vue avec BigQuery. Le mode `--dry_run` valide la requête et estime le volume traité.

```bash
bq --project_id=smartgrid-pulse --location=europe-west1 query \
  --use_legacy_sql=false --dry_run \
  'SELECT device_id, event_time, frequency_hz, grid_status FROM `smartgrid-pulse.gold_smartgrid.telemetry_latest`'
```

Dans la source de données de supervision Looker Studio, sélectionne le connecteur BigQuery, le projet `smartgrid-pulse`, le dataset `gold_smartgrid` et la vue `telemetry_latest`. Cette connexion donne accès aux champs même quand aucune mesure récente n’est disponible. Les requêtes du tableau de bord peuvent traiter des données BigQuery. [Connecteur BigQuery](https://docs.cloud.google.com/data-studio/connect-to-google-bigquery)

## Préparer la liaison Dataproc avec Cloud Storage et BigQuery

`terraform/dataproc.tf` active les API Managed Service for Apache Spark (Dataproc), Dataproc Resource Manager, Compute Engine et BigQuery Storage. Le premier test manuel vise le runtime Spark Serverless 3.0 avec les identifiants de l’utilisateur Cloud Shell. Le bucket Bronze et les datasets BigQuery existent déjà. Cette étape crée uniquement des activations d’API. [Runtime Spark Serverless 3.0](https://docs.cloud.google.com/managed-spark/docs/concepts/versions/spark-runtime-3.0)

Après avoir téléversé `dataproc.tf` dans ton dossier personnel Cloud Shell, génère et vérifie le plan.

```bash
cd ~/smartgrid-pulse/terraform &&
cp ~/dataproc.tf . &&
export TF_VAR_project_id=smartgrid-pulse &&
"$HOME/.local/bin/terraform" validate &&
"$HOME/.local/bin/terraform" plan -out=smartgrid-dataproc.tfplan
```

Les seules créations prévues sont les quatre instances `google_project_service.dataproc`. Après leur activation, vérifie les droits du compte qui soumettra le batch et le réseau dans `europe-west1`. La recette consiste ensuite à lire un objet Bronze déjà disponible et une table BigQuery, sans écrire de lignes. Le job de lecture et le pipeline historique se valident séparément. [Rôles Spark Serverless](https://docs.cloud.google.com/managed-spark/docs/concepts/personas-and-serverless-iam-roles)

```bash
gcloud compute networks subnets list --project=smartgrid-pulse --regions=europe-west1 \
  --format='table(name, network.basename(), privateIpGoogleAccess)'
gcloud storage ls --recursive gs://smartgrid-pulse-raw-bronze/iot/ | grep '\.ndjson$' | head -n 1
```

Le script `scripts/verify_dataproc_links.py` vérifie la lecture de l’objet NDJSON et du champ `date_key` de `gold_smartgrid.Dim_Date`. Les messages attendus sont `CLOUD_STORAGE_OK` et `BIGQUERY_OK`. Une dimension vide renvoie zéro ligne dans l’échantillon et permet de vérifier l’accès.

## Préparer les faits et les dimensions Gold

`terraform/silver_load.tf` crée le fait de charge et les dimensions calendrier dans Gold. Silver conserve les données nettoyées, dont la vue de télémétrie `telemetry_clean`. Les anciennes tables Silver sont conservées temporairement sur le projet déjà déployé.

| Couche | Table | Rôle et grain |
| --- | --- | --- |
| Gold | `gold_smartgrid.Fact_Energy_Load` | Une ligne par heure UTC pour la charge nationale espagnole, avec charge réelle, prévision de référence, prix spot et production par filière. La table est partitionnée par `timestamp_utc` et les requêtes doivent filtrer la période. |
| Gold | `gold_smartgrid.Dim_Date` | Une ligne par jour métier en `Europe/Madrid`, avec une clé `AAAAMMJJ`, le jour de la semaine, le week-end et la saison. |
| Gold | `gold_smartgrid.Dim_Time` | Une ligne par minute locale, avec une clé numérique `HHMM` et les plages de pointe `[08:00, 12:00)` et `[18:00, 22:00)`. |

Les clés `date_key` et `time_key` de `Fact_Energy_Load` relient le fait aux dimensions Gold. Elles sont calculées à partir de `timestamp_utc` converti en `Europe/Madrid`. Au changement d’heure, deux créneaux locaux identiques peuvent correspondre à deux heures UTC distinctes. Le fait garde son grain national et sa clé stable SHA-256 calculée sur le pays et l’heure UTC. La dimension Ville et le fait météo sont prévus en Gold dans la partie d’Abarkha.

### Créer le fait Gold sur le projet déjà déployé

Le dataset Gold et les dimensions calendrier sont déjà déployés. Téléverse la version mise à jour de `silver_load.tf` dans ton dossier personnel Cloud Shell. Active la conservation temporaire du fait de charge Silver et garde le fichier de migration du calendrier. Sur un nouveau projet, les tables métier sont créées directement en Gold.

```bash
cd ~/smartgrid-pulse/terraform &&
cp ~/silver_load.tf silver_load.tf &&
printf 'keep_legacy_silver_load = true\n' > silver-load-migration.auto.tfvars &&
export TF_VAR_project_id=smartgrid-pulse &&
tf="$HOME/.local/bin/terraform" &&
"$tf" validate &&
"$tf" plan -out=smartgrid-gold-load.tfplan
```

Sur le projet existant, le plan attendu ajoute `gold_fact_energy_load` avec zéro modification et zéro destruction. Le bloc `moved` conserve le suivi du fait Silver sous l’adresse `fact_energy_load[0]`. Après vérification, applique le plan avec `"$tf" apply smartgrid-gold-load.tfplan`. Consulte le compteur `numRows` de la table Silver avant toute copie ou suppression. Si elle contient des lignes, transfère-les et vérifie le résultat avant de retirer la table Silver dans une étape séparée. [Déplacements d’adresses Terraform](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)

### Initialiser les dimensions Gold

Après création des tables Gold, importe la version mise à jour de `sql/seed_calendar.sql` dans ton dossier personnel Cloud Shell. Adapte les dates aux bornes locales de l’extrait historique dès qu’elles sont connues. L’exemple couvre 2015–2018.

```bash
bq --project_id=smartgrid-pulse --location=europe-west1 query \
  --use_legacy_sql=false --maximum_bytes_billed=104857600 \
  --parameter='start_date:DATE:2015-01-01' \
  --parameter='end_date:DATE:2018-12-31' < ~/seed_calendar.sql
```

Pour cette période, attends 1 461 dates et 1 440 minutes. Le script `MERGE` peut être relancé sans ajouter les clés déjà présentes. `is_holiday_spain` reste `NULL` pour les nouvelles dates jusqu’au chargement du calendrier officiel. `Fact_Energy_Load` attend les données horaires préparées par Abarkha.
