# The CalmOps web server in one box: Linux, Python 3.13, the runtime libraries
# and the code. Same Python as the .venv the tests and evals ran on.
#   docker build -t calmops:0.1 .
#   docker run --rm -p 8000:8000 -e AZURE_OPENAI_ENDPOINT=https://... calmops:0.1
FROM python:3.13-slim

# No .pyc files, and log lines show up at once instead of being buffered.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Libraries before code: this layer is rebuilt only when requirements.txt
# changes, not on every code change.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Only what the server loads. No tests, evals, desktop window or notes.
COPY api.py cli.py ./
COPY agent/ agent/
COPY observability/__init__.py observability/tracing.py observability/
COPY tools/ tools/
COPY static/ static/

# Every user file (check-ins, measures, consent, per-turn records) goes to
# /data. Step 8 mounts the Azure Files share there; until then it is lost
# when the container stops.
ENV CALMOPS_DATA_DIR=/data
RUN useradd --create-home --uid 1000 calmops && mkdir /data && chown calmops /data
USER calmops

EXPOSE 8000
# One process, no --workers: the approval pause lives in memory (InMemorySaver),
# so every request must reach the same process. --host 0.0.0.0 so the server
# can be reached from outside the container.
CMD ["uvicorn", "api:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000"]
