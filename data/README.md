# Donnees SmartGrid Pulse

Les donnees Londres sont externes au depot Git. Elles proviennent du dataset
Kaggle `jeanmidev/smart-meters-in-london` et ne doivent jamais etre commitees.

Organisation locale cible :

```text
data/
  raw/          # archive et CSV Kaggle non modifies
  processed/    # historique nettoye 2011-2013
  replay/       # extrait reel janvier-fevrier 2014 reserve au replay
  checkpoints/  # progression locale du replay
```

Fichiers sources attendus :

- `halfhourly_dataset/block_*.csv` ou `hhblock_dataset/block_*.csv` ;
- `informations_households.csv` ;
- `weather_hourly_darksky.csv` ;
- `weather_daily_darksky.csv` ;
- `uk_bank_holidays.csv` ;
- `acorn_details.csv` (reference facultative pour l'analyse demographique).

Regle temporelle obligatoire :

- novembre 2011 a decembre 2013 : historique batch et entrainement ;
- janvier-fevrier 2014 : donnees cachees de l'entrainement, reservees au replay
  streaming et a l'evaluation finale.

Les fichiers de donnees restent ignores par `.gitignore`. Seul ce guide est
versionne.
