import argparse

from pyspark.sql import SparkSession


def main():
    parser = argparse.ArgumentParser(
        description="Vérifie que Spark peut lire une archive Bronze et le calendrier Gold."
    )
    parser.add_argument("--project", required=True)
    parser.add_argument("--archive", required=True, help="URI gs:// d’un fichier NDJSON existant")
    args = parser.parse_args()

    if not args.archive.startswith("gs://") or not args.archive.endswith(".ndjson"):
        parser.error("--archive doit désigner un fichier gs:// se terminant par .ndjson")

    spark = SparkSession.builder.appName("SmartGrid Pulse - vérification Dataproc").getOrCreate()
    try:
        if not spark.read.text(args.archive).take(1):
            raise RuntimeError("Le fichier d’archive est vide.")
        print("CLOUD_STORAGE_OK", flush=True)

        calendar = spark.read.format("bigquery").load(
            f"{args.project}.gold_smartgrid.Dim_Date"
        )
        sample = calendar.select("date_key").take(1)
        print(f"BIGQUERY_OK lignes_échantillon={len(sample)}", flush=True)
    finally:
        spark.stop()


if __name__ == "__main__":
    main()
