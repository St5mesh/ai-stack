FROM python:3.11-slim

RUN pip install --no-cache-dir \
        open-interpreter \
        playwright \
        qdrant-client \
        "fastapi>=0.110.0" \
        "uvicorn[standard]>=0.27.0" \
    && python -m playwright install chromium \
    && python -m playwright install-deps chromium

COPY gateway.py /app/gateway.py

WORKDIR /workspace
EXPOSE 8888
CMD ["uvicorn", "--app-dir", "/app", "gateway:app", "--host", "0.0.0.0", "--port", "8888"]
