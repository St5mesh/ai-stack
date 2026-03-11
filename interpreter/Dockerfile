FROM python:3.11-slim

RUN pip install --no-cache-dir open-interpreter playwright qdrant-client \
    && python -m playwright install chromium \
    && python -m playwright install-deps chromium

WORKDIR /workspace
CMD ["tail", "-f", "/dev/null"]
