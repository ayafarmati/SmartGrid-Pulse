FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY replay/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY replay/app.py replay/core.py ./
COPY schemas/energy_replay_event.schema.json ./energy_replay_event.schema.json

RUN useradd --create-home --uid 10001 replay
USER replay

ENTRYPOINT ["python", "app.py"]
