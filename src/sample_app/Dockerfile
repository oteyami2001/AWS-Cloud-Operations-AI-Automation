FROM public.ecr.aws/docker/library/python:3.13-slim

# Non-root, read-only friendly, no extra packages (stdlib-only app).
RUN useradd --uid 10001 --create-home app
WORKDIR /app
COPY app.py .
USER 10001
ENV PORT=8080 PYTHONUNBUFFERED=1
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health').status==200 else 1)"
CMD ["python", "app.py"]
