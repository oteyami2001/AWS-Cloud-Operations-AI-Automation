FROM public.ecr.aws/docker/library/python:3.13-slim

# Runtime hardening for a stdlib-only app:
#  - apply Debian security updates published after the base image was built
#  - remove pip (+ its vendored libraries and their SBOM): never needed at runtime, and the
#    vendored copies are a recurring source of HIGH CVEs flagged by the CI Trivy gate
#  - non-root user, compatible with a read-only root filesystem (ECS readonlyRootFilesystem)
RUN apt-get update \
 && apt-get -y --no-install-recommends upgrade \
 && rm -rf /var/lib/apt/lists/* \
 && python -m pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3.13/ensurepip \
 && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --chown=root:root --chmod=0444 app.py .
USER 10001
ENV PORT=8080 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health').status==200 else 1)"]
CMD ["python", "app.py"]
