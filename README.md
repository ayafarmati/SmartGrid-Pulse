# SmartGrid Pulse

Projet  pour la prévision de la demande électrique et la supervision de cinq sous-stations simulées sur Google Cloud.

Le socle Terraform **Pub/Sub → BigQuery Bronze** est validé sur GCP en `europe-west1`. Un test a confirmé la livraison d’un message texte et la lecture des mesures d’un relevé JSON. Le simulateur Python génère des lots de cinq relevés et a été testé localement. Son déploiement sur Cloud Run est le prochain jalon.

## Structure du code

- `terraform/` contient les API, le topic Pub/Sub, la souscription, la table Bronze et ses règles d’accès.
- `simulator/telemetry.py` génère les relevés normaux et les scénarios d’alerte.

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

Le second test doit afficher un événement `UNDER_FREQUENCY` à `49.7 Hz` pour Madrid, et quatre événements `NORMAL`. Les scénarios `surfrequence`, `surtension` et `surchauffe` sont également disponibles. Le test local ne consomme aucune ressource GCP. Le jalon suivant publiera un lot à la demande dans Pub/Sub depuis Cloud Run.
