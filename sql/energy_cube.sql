-- Paramètres TIMESTAMP : event_start et event_end (borne exclue).
WITH observations AS (
  SELECT
    EXTRACT(YEAR FROM DATETIME(timestamp_utc, 'Europe/Madrid')) AS year_local,
    EXTRACT(MONTH FROM DATETIME(timestamp_utc, 'Europe/Madrid')) AS month_local,
    EXTRACT(HOUR FROM DATETIME(timestamp_utc, 'Europe/Madrid')) AS hour_local,
    actual_load_mw,
    generation_solar_mw,
    generation_wind_onshore_mw,
    price_spot_eur_mwh
  FROM `smartgrid-pulse.gold_smartgrid.Fact_Energy_Load`
  WHERE timestamp_utc >= @event_start AND timestamp_utc < @event_end
)
SELECT
  year_local, month_local, hour_local,
  GROUPING(year_local) AS all_years,
  GROUPING(month_local) AS all_months,
  GROUPING(hour_local) AS all_hours,
  COUNT(*) AS observations,
  AVG(actual_load_mw) AS average_load_mw,
  MAX(actual_load_mw) AS peak_load_mw,
  SUM(actual_load_mw * 1.0) AS observed_energy_mwh,
  AVG(generation_solar_mw) AS average_solar_mw,
  AVG(generation_wind_onshore_mw) AS average_wind_mw,
  AVG(price_spot_eur_mwh) AS average_price_eur_mwh
FROM observations
GROUP BY GROUPING SETS (
  ROLLUP(year_local, month_local),
  (hour_local),
  (year_local, hour_local),
  (year_local, month_local, hour_local)
);
-- Pour une coupe croisée année × heure, remplacer la dernière clause par
-- GROUP BY CUBE(year_local, hour_local, month_local).
