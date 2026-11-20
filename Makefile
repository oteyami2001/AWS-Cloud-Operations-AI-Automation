# Local targets never touch AWS unless their name says so (push-image, deploy-*, destroy).
TF_DEV := terraform -chdir=terraform/envs/dev
PY     ?= python3

.PHONY: help install lint test tf-fmt tf-validate tf-test checkov demo-local load-test-local evidence \
        build push-image plan deploy destroy

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-18s %s\n", $$1, $$2}'

install: ## Install dev dependencies
	$(PY) -m pip install -r requirements-dev.txt

lint: ## Ruff + bandit
	ruff check src tests scripts
	ruff format --check src tests scripts
	bandit -q -c pyproject.toml -r src scripts

test: ## Unit/integration tests with coverage gate (local, no AWS)
	$(PY) -m pytest --cov --cov-report=term

tf-fmt: ## terraform fmt check
	terraform -chdir=terraform fmt -check -recursive

tf-validate: build ## terraform validate (local, no AWS)
	$(TF_DEV) init -backend=false -input=false >/dev/null && $(TF_DEV) validate
	terraform -chdir=terraform/bootstrap init -backend=false -input=false >/dev/null && terraform -chdir=terraform/bootstrap validate

tf-test: ## Offline terraform tests with mocked providers (local, no AWS)
	$(TF_DEV) test
	terraform -chdir=terraform/modules/aiops init -backend=false -input=false >/dev/null && terraform -chdir=terraform/modules/aiops test

checkov: ## IaC security scan
	checkov -d terraform --framework terraform --quiet --compact

demo-local: ## Offline end-to-end incident simulation
	$(PY) scripts/local_demo.py

load-test-local: ## Run the sample app locally and load test it
	cd src/sample_app && FAULT_TOKEN=local PORT=18080 $(PY) app.py & echo $$! > /tmp/aiops-app.pid; sleep 1; \
	$(PY) scripts/load_test.py --url http://127.0.0.1:18080 --path "/work?ms=5" --duration 20 --concurrency 10 \
	  --label local-sample-app --out docs/evidence/local/load-tests; kill $$(cat /tmp/aiops-app.pid)

build: ## Build build/lambda.zip
	scripts/build_lambda.sh

# ---- AWS (billable) -------------------------------------------------------------------
push-image: ## [AWS] Build and push the sample app image to ECR
	@REPO=$$($(TF_DEV) output -raw ecr_repository_url); TAG=$${TAG:-v1}; \
	aws ecr get-login-password | docker login --username AWS --password-stdin $${REPO%%/*} && \
	docker build -t $$REPO:$$TAG src/sample_app && docker push $$REPO:$$TAG

plan: build ## [AWS read-only] terraform plan
	$(TF_DEV) init -input=false && $(TF_DEV) plan -out=tfplan

deploy: ## [AWS] apply the saved plan (run `make plan` first and review it)
	$(TF_DEV) apply tfplan

destroy: ## [AWS] destroy the dev environment (see docs/cleanup.md)
	$(TF_DEV) destroy
