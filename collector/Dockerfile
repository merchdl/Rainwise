FROM python:3.12-slim

WORKDIR /app
COPY pyproject.toml ./
COPY rainwise_collector ./rainwise_collector
RUN pip install --no-cache-dir .

ENV DB_PATH=/data/rainwise.db \
    PORT=8100 \
    PYTHONUNBUFFERED=1
VOLUME /data
EXPOSE 8100

HEALTHCHECK --interval=60s --timeout=5s \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8100/api/health').status == 200 else 1)"

CMD ["rainwise-collector"]
