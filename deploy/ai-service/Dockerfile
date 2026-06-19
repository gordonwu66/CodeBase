# Minimal, dependency-free image for the Phase 3 AI companion scaffold.
FROM python:3.12-slim

WORKDIR /app
COPY app.py .

# Drop root — the service needs no privileges (unlike the runner, it executes no repo code).
RUN useradd --no-create-home --uid 10001 appuser
USER appuser

EXPOSE 8080
CMD ["python", "app.py"]
