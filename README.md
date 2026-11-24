# SmartGrid Pulse London

Plateforme Big Data sur Google Cloud pour analyser et prévoir la consommation électrique résidentielle de foyers londoniens.

Le projet utilise les mesures réelles du dataset **Smart Meters in London** selon deux traitements complémentaires :

- **Batch historique** : novembre 2011 à décembre 2013 pour l’analyse, la préparation des variables et l’entraînement du modèle.
- **Replay streaming** : janvier à février 2014, publié progressivement dans Pub/Sub comme si les compteurs transmettaient leurs mesures en temps réel.

Les valeurs 2014 sont de véritables mesures historiques. Seul leur rythme d’arrivée est simulé. Le projet ne prétend pas disposer d’une source live en 2026.

[Architecture Londres v5](architecture-smartgrid-pulse-looker_londres_v5.png) · [Guide PDF Londres v4](docs/SmartGrid-Pulse-guide-donnees_londres_v4.pdf)

## Problématique

Comment prévoir, heure par heure, la consommation électrique des foyers londoniens pour les 24 prochaines heures, superviser l’arrivée des mesures et détecter les anomalies de consommation ou de collecte ?

Le système doit :

1. conserver l’historique brut et traçable ;
2. nettoyer et enrichir les mesures avec la météo, le calendrier et les profils des ménages ;
3. entraîner un modèle exclusivement sur les données disponibles avant 2014 ;
4. rejouer progressivement les mesures 2014 dans Pub/Sub ;
5. déclencher des prévisions T+1 à T+24 pendant le replay ;
6. comparer les valeurs reçues aux prévisions enregistrées ;
7. présenter les résultats dans Looker/LookML.

## Dataset

Source principale : [Smart Meters in London](https://www.kaggle.com/datasets/jeanmidev/smart-meters-in-london).

| Fichier | Utilisation | Responsable |
| --- | --- | --- |
| `halfhourly_dataset.zip` / `block_*.csv` | Mesures en kWh par ménage et par demi-heure | Abarkha pour le batch, Aya pour le replay 2014 |
| `informations_households.csv` | Métadonnées des ménages, groupe tarifaire et profil ACORN | Abarkha |
| `weather_hourly_darksky.csv` | Observations météo horaires de Londres | Abarkha |
| `uk_bank_holidays.csv` | Jours fériés du calendrier | Abarkha |
| `daily_dataset*` | Vérification des agrégations journalières | Secondaire |
| `acorn_details.csv` | Analyse socio-économique avancée | Optionnel |

Champs essentiels des blocs demi-horaires :

```text
LCLid              identifiant anonymisé du compteur/ménage
tstp               horodatage de la mesure
energy(kWh/hh)     énergie consommée pendant la demi-heure
```

Le dataset ne fournit pas le borough exact de chaque foyer et ne permet pas de rattacher les ménages à de véritables sous-stations. Le modèle utilise donc `Dim_Meter` et cinq `Dim_Virtual_Group` déterministes, et non `Dim_City` ou de vraies sous-stations.

## Découpage temporel anti-fuite

| Période | Utilisation | Mode |
| --- | --- | --- |
| Novembre 2011 à décembre 2012 | Entraînement initial | Batch |
| Année 2013 | Validation chronologique et sélection du modèle | Batch |
| Janvier à février 2014 | Replay, scoring et évaluation en conditions simulées | Streaming |

Les mesures 2014 ne doivent jamais être chargées à l’avance dans les tables ou variables accessibles au modèle. Elles deviennent visibles seulement après leur publication dans Pub/Sub.

Après la sélection des hyperparamètres, le modèle peut être réentraîné sur l’ensemble 2011–2013 avant le démarrage du replay.

## Architecture

```text
                          BATCH HISTORIQUE 2011-2013

CSV Londres ──> GCS Bronze ──> Dataproc/PySpark ──> BigQuery Silver
                                                       │
                                                       v
                                           BigQuery Gold + features
                                                       │
                                                       v
                                            Spark ML + Model Registry

                         REPLAY STREAMING JAN-FÉV 2014

GCS Replay ──> Cloud Run Job ──> Pub/Sub ──> Bronze ──> Silver replay
                                               │              │
                                               v              v
                                         Archive GCS    Fact_Energy_Load
                                                              │
                                                              v
                                                    Service d’inférence
                                                              │
                                                              v
                                                 Fact_Load_Predictions
                                                              │
                                                              v
                                                      Looker / LookML
```

L’infrastructure cible reste en `europe-west1` et utilise Cloud Storage, Dataproc Serverless, Pub/Sub, Cloud Run Job, BigQuery, Spark ML, Vertex AI Model Registry, Cloud Composer, Looker/LookML, Terraform, IAM, Artifact Registry, GitHub Actions/WIF et Dataplex.

## Répartition des responsabilités

| Personne | Responsabilités |
| --- | --- |
| **Abarkha** | Sources historiques, météo, métadonnées, ETL PySpark, qualité, anomalies historiques, préparation du jeu d’entraînement, règles d’alerte et analyse de supervision |
| **Aya** | Séparation et isolation du replay 2014, replay Python, Cloud Run, Pub/Sub, Bronze/Silver streaming, DLQ, Logging, Monitoring, Gold de charge, modèle Spark ML, scoring, Looker/LookML |
| **Partagé** | Contrat des tables, tests de bout en bout, validation des métriques, documentation, lineage et démonstration finale |

Abarkha remet à Aya :

- `silver_smartgrid.london_consumption_hourly` ;
- `silver_smartgrid.london_weather_hourly` ;
- `gold_smartgrid.Dim_Meter` ;
- `gold_smartgrid.Dim_Virtual_Group` ;
- `gold_smartgrid.Fact_Weather_Obs` ;
- un rapport de qualité et les bornes temporelles validées.

## Organisation Cloud Storage cible

```text
smartgrid-bronze/
├── historical/energy/2011/
├── historical/energy/2012/
├── historical/energy/2013/
├── historical/weather/
├── reference/households/
├── reference/holidays/
└── streaming/archive/

smartgrid-replay/
├── energy/event_date=2014-01-01/
├── energy/event_date=2014-01-02/
├── weather/2014/
└── checkpoints/

smartgrid-models/
├── forecasting/
└── anomaly_detection/
```

Le bucket de replay est isolé. Seul le compte de service du Cloud Run Job doit pouvoir lire les mesures futures de 2014.

## Pipeline batch 2011–2013

Le job PySpark lit tous les `block_*.csv`, parse `tstp`, convertit l’énergie en numérique et sépare les lignes avec `year(event_time) <= 2013`.

Transformations principales :

- renommage et standardisation des colonnes ;
- conversion de `energy(kWh/hh)` en `DOUBLE` ;
- déduplication par `meter_id` et `event_time` ;
- contrôle des valeurs nulles, négatives et des demi-heures manquantes ;
- ajout des métadonnées ménage et de la météo horaire ;
- conservation du fichier/bloc source et de l’heure d’ingestion ;
- agrégations horaires par compteur et par groupe virtuel ;
- création des variables historiques sans fuite temporelle.

La puissance moyenne sur une demi-heure peut être dérivée sans inventer une mesure instantanée :

```text
avg_power_kw = energy_kwh / 0,5 = 2 × energy_kwh
```

## Replay streaming 2014

Le producteur d’Aya ne génère plus de fréquence, de tension ni de consommation fictive. Il lit les véritables mesures 2014 isolées dans GCS.

Configuration pilote recommandée :

- 100 compteurs ;
- cinq groupes virtuels déterministes ;
- un créneau de 30 minutes publié toutes les cinq secondes ;
- checkpoint après chaque créneau publié ;
- reprise sans republier les événements déjà confirmés.

Le Cloud Run Job charge le checkpoint, lit le prochain créneau, construit un événement par compteur, publie dans Pub/Sub, attend l’intervalle configuré et sauvegarde sa progression.

Exemple d’événement :

```json
{
  "event_id": "MAC000001_20140101T003000",
  "meter_id": "MAC000001",
  "virtual_group_id": "GROUP_01",
  "event_time": "2014-01-01T00:30:00Z",
  "ingestion_time": "2026-11-24T21:00:00Z",
  "energy_kwh": 0.42,
  "source": "STREAM_REPLAY",
  "schema_version": "1.0"
}
```

`event_time` représente la date réelle de mesure. `ingestion_time` représente l’entrée dans GCP. Les jointures métier et les variables temporelles utilisent `event_time`.

## Pub/Sub

Topic cible : `smart-meter-events`.

| Abonnement | Rôle |
| --- | --- |
| `sub-meter-bigquery` | Écrire les événements dans BigQuery Bronze |
| `sub-meter-archive` | Archiver le JSON brut dans Cloud Storage |
| `sub-meter-alerts` | Déclencher les contrôles et le scoring via Cloud Run |
| `sub-meter-dlq` | Permettre la lecture des messages redirigés vers la DLQ |

## Modèle BigQuery Gold

| Table | Grain et rôle |
| --- | --- |
| `Dim_Meter` | Un compteur/ménage anonymisé et ses attributs disponibles |
| `Dim_Date` | Une date locale `Europe/London` |
| `Dim_Time` | Un créneau horaire ou demi-horaire |
| `Dim_Virtual_Group` | Un des cinq groupes déterministes de compteurs |
| `Fact_Energy_Load` | Une mesure de consommation, batch ou replay |
| `Fact_Weather_Obs` | Une observation météo horaire de Londres |
| `Fact_Load_Predictions` | Une prévision par heure cible, horizon et version du modèle |
| `Fact_Anomalies` | Une anomalie de données, de consommation ou de prévision |

`Fact_Energy_Load.source` distingue `BATCH` pour 2011–2013 et `STREAM_REPLAY` pour les données 2014 reçues via Pub/Sub.

La table est partitionnée par la date de `event_time` et clusterisée par `meter_id`, éventuellement aussi par `virtual_group_id`. Les chargements streaming vers Gold utilisent un `MERGE` idempotent sur `event_id`.

## Machine Learning

Premier modèle recommandé : consommation agrégée par groupe virtuel et par heure.

Variables candidates : `lag_1h`, `lag_24h`, `lag_168h`, `rolling_mean_24h`, `rolling_mean_7d`, heure, jour de semaine, jour férié, température, humidité, compteurs actifs et groupe virtuel.

Le découpage train/validation/test est chronologique. Les variables retardées sont calculées sur de vrais intervalles temporels. Les métriques sont MAE, RMSE et WAPE, globalement et pour chaque horizon T+1 à T+24.

Pendant le replay, le service d’inférence utilise uniquement les événements déjà reçus. Une observation météo future ne doit pas être utilisée comme si elle était disponible à l’heure de prévision.

## Alertes et anomalies

```text
Pub/Sub → Cloud Run → Cloud Logging → Cloud Monitoring
```

Règles adaptées : énergie négative, JSON invalide, timestamp absent, doublon, mesure manquante, compteur silencieux, surconsommation et résidu de prévision anormal.

La détection des retards utilise l’horloge accélérée du replay, pas un délai réel de trente minutes.

## Cloud Composer

Trois DAGs sont prévus :

- `historical_pipeline` : GCS → Dataproc → qualité → Silver → Gold → features ;
- `model_training_pipeline` : features → entraînement → évaluation → versionnement ;
- `streaming_replay_pipeline` : vérifications → Cloud Run Job → supervision → contrôle de complétude.

Composer orchestre les traitements. Il ne traite pas chaque message Pub/Sub.

## Looker et LookML

Le dashboard final contient quatre pages :

1. **Analyse historique** : consommation 2011–2013, saisonnalité et profils ACORN ;
2. **Replay monitoring** : progression, compteurs actifs et derniers événements 2014 ;
3. **Forecasting** : réel/prévu, T+1 à T+24, MAE/RMSE/WAPE et version du modèle ;
4. **Data Quality & Alerts** : anomalies, doublons, messages invalides et données manquantes.

Le modèle LookML part de `Fact_Load_Predictions` et utilise des relations `many_to_one` vers les dimensions.

## État actuel et cible

| Composant | État | Action |
| --- | --- | --- |
| Terraform, IAM, Artifact Registry | Socle existant | Conserver et adapter les droits |
| Pub/Sub, archive GCS et DLQ | Code adapté au schéma Londres | Valider le plan Terraform puis migrer sans perte |
| Replay Python | Lecteur CSV Londres et contrat d’événement implémentés | Tester avec l’extrait réel 2014 |
| Cloud Run | Service de replay adapté | Construire l’image puis tester `/replay` avec GCS |
| Dataproc Serverless | Connectivité validée | Implémenter l’ETL 2011–2013 |
| BigQuery Bronze/Silver | Code Londres prêt | Valider puis appliquer depuis le state Cloud Shell |
| BigQuery Gold | Dimensions et faits Londres définis | Valider la migration des anciennes tables vides |
| Spark ML / Model Registry | Cible | Entraîner et versionner le modèle |
| Data Studio | Rapport technique validé | Remplacer par les indicateurs Londres |
| Looker/LookML | Cible | Créer les Explores et le dashboard final |

## Structure du dépôt

```text
smartgrid-pulse/
├── terraform/       infrastructure GCP
├── simulator/       service de replay des mesures Londres 2014
├── tests/           tests unitaires du contrat d’événement
├── data/            structure locale; données volumineuses ignorées par Git
├── scripts/         recettes et contrôles techniques
├── sql/             initialisation et transformations BigQuery
├── docs/            guide PDF de référence
└── README.md
```

## Prochain ordre d’exécution

1. télécharger et auditer les blocs CSV ;
2. mesurer la couverture réelle par compteur et par année ;
3. séparer physiquement 2011–2013 et 2014 ;
4. créer les cinq groupes virtuels ;
5. valider dans Cloud Shell le Terraform Londres déjà préparé ;
6. adapter le batch PySpark historique ;
7. charger les dimensions et faits Gold ;
8. entraîner et versionner le premier modèle ;
9. tester le replay Python avec l’extrait réel 2014 ;
10. ajouter le scoring, Looker/LookML et la recette de bout en bout.

## Validation Terraform

```bash
cd terraform
terraform fmt -check
terraform init
terraform validate
terraform plan
```

Toujours relire le plan avant `terraform apply`. Le projet déployé possède déjà un état Terraform dans Cloud Shell. Les changements doivent être appliqués depuis ce même état ou après une migration contrôlée du backend.

