# Local targets never touch AWS unless their name says so (push-image, deploy-*, destroy).
TF_DEV := terraform -chdir=terraform/envs/dev
PY     ?= python3

.PHONY: help install lint test tf-fmt tf-validate tf-test tflint trivy checkov demo-local load-test-local evidence \
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

TF_TEST_DIRS := bootstrap envs/dev modules/aiops modules/workload

tf-validate: ## terraform validate (local, no AWS)
	@for d in $(TF_TEST_DIRS); do terraform -chdir=terraform/$$d init -backend=false -input=false >/dev/null && \
	  echo "$$d: $$(terraform -chdir=terraform/$$d validate -no-color | head -1)" || exit 1; done

tf-test: ## Offline terraform tests with mocked providers (local, no AWS)
	@for d in $(TF_TEST_DIRS); do echo "== $$d"; terraform -chdir=terraform/$$d test || exit 1; done

tflint: ## tflint (recommended preset + AWS ruleset)
	tflint --init --config "$(CURDIR)/.tflint.hcl" && tflint --recursive --config "$(CURDIR)/.tflint.hcl" --chdir terraform

trivy: ## Trivy config + filesystem (dependencies, secrets) scan
	trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 .
	trivy fs --quiet --scanners vuln,secret,misconfig --severity HIGH,CRITICAL --skip-dirs build --exit-code 1 .

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
push-image: ## [AWS] Build and push the sample app image to the bootstrap ECR repository (TAG=v1)
	@REPO=$$(terraform -chdir=terraform/bootstrap output -raw ecr_repository_url); TAG=$${TAG:-v1}; \
	aws ecr get-login-password --region $${AWS_REGION:-us-east-2} | docker login --username AWS --password-stdin $${REPO%%/*} && \
	docker build -t $$REPO:$$TAG src/sample_app && docker push $$REPO:$$TAG

plan: build ## [AWS read-only] terraform plan
	$(TF_DEV) init -input=false && $(TF_DEV) plan -out=tfplan

deploy: ## [AWS] apply the saved plan (run `make plan` first and review it)
	$(TF_DEV) apply tfplan

destroy: ## [AWS] destroy the dev environment (see docs/cleanup.md)
	$(TF_DEV) destroy
