FROM python:3.12-slim
RUN pip install --no-cache-dir "psycopg[binary]"
WORKDIR /app
COPY schema.sql mapquest_server.py ./
EXPOSE 8080
CMD ["sh", "-c", "python mapquest_server.py migrate && python mapquest_server.py serve --host 0.0.0.0 --port 8080"]
