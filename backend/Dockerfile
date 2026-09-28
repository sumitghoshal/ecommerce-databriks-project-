FROM python:3.11-slim

# Non-root user: ECS tasks should not run as root (Section 12 hardening)
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /app

# Install deps first so Docker layer-caches them independently of app code
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')"

# 2 workers x 4 threads fits the 0.5 vCPU / 1GB Fargate task size in Section 2
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--threads", "4", \
     "--timeout", "60", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
