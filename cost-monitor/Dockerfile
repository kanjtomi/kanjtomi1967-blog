# AWS cost monitor. Stdlib-only (monitor.py signs Cost Explorer requests itself),
# so there is no pip install and no boto3 in the image.
FROM docker.io/library/python:3.12-alpine

WORKDIR /app
COPY monitor.py .
RUN adduser -D -u 10001 app
USER 10001

ENV PORT=8080 PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["python", "/app/monitor.py"]
