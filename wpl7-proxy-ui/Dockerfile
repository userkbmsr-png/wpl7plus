FROM python:3.13-alpine

RUN apk add --no-cache ca-certificates
WORKDIR /app
COPY app.py ./
COPY static ./static

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1
CMD ["python", "/app/app.py"]
