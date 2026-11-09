FROM python:3.13-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY exporter.py exporter_queries.yaml ./
USER 65534:65534
EXPOSE 9187
CMD ["python", "-u", "exporter.py"]
