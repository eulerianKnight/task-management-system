# Multi-Stage Docker build
FROM python:3.13-slim as base

# Set Environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Development Stage \
FROM base as development

WORKDIR /app

# Copy requirements.txt
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy APplication code
COPY . .

# Create non-root user for security
RUN groupadd -r appuser && useradd -r -g appuser
RUN chown -R appuser:appuser /app
USER appuser

# Expose Port
EXPOSE 8000

# Command for development
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]

# Production Stage
FROM base as production

WORKDIR /app

# Copy requirements.txt
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create non-root user for security (kubernetes security best practice)
RUN groupadd -r appuser && useradd -r -g appuser appuser
RUN chown -R appuser:appuser /app
USER appuser

# Health Check
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 CMD curl -f http://localhost:8000/health || exit 1

# Expose Port
EXPOSE 8000

# Production command
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]



