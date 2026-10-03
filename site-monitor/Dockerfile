# Lightweight uptime/response-time monitor for the blog's public URLs.
# Stdlib-only script (see monitor.py) so no pip install / requirements.txt
# is needed - keeps the image small and the build free of a package-index
# dependency.

FROM docker.io/library/python:3.12-alpine

WORKDIR /app
COPY monitor.py .

ENV PORT=8080
EXPOSE 8080

USER nobody
ENTRYPOINT ["python", "monitor.py"]
