# Migration contrôlée vers Londres

Le code du dépôt décrit désormais uniquement le pipeline London Smart Meters.
Le state actif se trouve toutefois dans Cloud Shell et référence encore les
ressources du prototype précédent. Ne jamais appliquer ce code avec un state
vide.

## Changements attendus dans le plan

- remplacement du topic par `smart-meter-events` ;
- remplacement des abonnements par `sub-meter-bigquery` et
  `sub-meter-archive` ;
- remplacement de la DLQ par `smart-meter-dlq` et `sub-meter-dlq` ;
- remplacement du compte de service par `sa-meter-replay` ;
- mise à jour en place des vues `telemetry_clean` et `telemetry_latest` ;
- modification du schéma des tables Gold actuellement vides.

Les ressources Pub/Sub utilisent `create_before_destroy` afin que leurs
remplaçantes soient créées avant la suppression de l'ancien nom.

## Procédure obligatoire

1. Dans Cloud Shell, sauvegarder le state :

   ```bash
   cd ~/smartgrid-pulse/terraform
   cp terraform.tfstate "terraform.tfstate.before-london-$(date +%Y%m%d-%H%M%S)"
   ```

2. Récupérer la branche `feat/london-smart-meter-pipeline` dans un clone Git
   propre. Ne pas copier un nouveau `terraform.tfstate` par-dessus celui de
   Cloud Shell.

3. Exécuter uniquement :

   ```bash
   terraform init
   terraform fmt -check -recursive
   terraform validate
   terraform plan -out=smartgrid-london.tfplan
   ```

4. Inspecter tous les remplacements et toutes les suppressions :

   ```bash
   terraform show -json smartgrid-london.tfplan |
     jq -r '.resource_changes[] |
       select(.change.actions | index("delete")) |
       "\(.address) -> \(.change.actions | join(","))"'
   ```

5. Ne pas appliquer tant que le plan tente de supprimer le bucket Bronze, le
   dataset BigQuery ou une table contenant des données.

6. Les anciennes tables Gold ont été observées avec zéro ligne. Vérifier de
   nouveau ce nombre juste avant leur migration. Leur protection devra être
   retirée dans une étape séparée uniquement si le provider exige un
   remplacement de schéma.

7. Après application, publier un seul message Londres, puis vérifier dans cet
   ordre : Pub/Sub, Bronze, Silver, Gold, archive GCS et DLQ.

## Retour arrière

Conserver le state sauvegardé et l'image Cloud Run précédente jusqu'à la fin
de la recette. Un retour arrière ne doit être décidé qu'après comparaison du
state courant, du plan inverse et des données déjà reçues par les nouveaux
topics.
