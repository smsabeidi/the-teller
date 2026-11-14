FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py account.py story_import.py book_catalog.py human_audio.py catalog_seed.json ./
COPY static ./static
RUN mkdir -p /app/data
EXPOSE 8000
# One worker: export progress lives in memory
CMD ["sh","-c","exec uvicorn server:app --host 0.0.0.0 --port ${PORT:-8000} --no-access-log"]
