# Deliberately small and boring. This image exists to crash convincingly.
FROM python:3.12-slim

WORKDIR /app

RUN adduser --disabled-password --gecos "" checkout
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
USER checkout

EXPOSE 8080

# exec form, so the process is PID 1 and receives SIGTERM directly. Without
# this, a shell wraps it, signals go to the wrong process, and the exit codes
# the Diagnostician reads become meaningless.
CMD ["python", "main.py"]
