# cicd-demo — local bootstrap & demo helpers
# Prereqs: docker, kind, kubectl, kustomize (or kubectl -k), and a browser.

CLUSTER        ?= cicd-demo
ARGOCD_VERSION ?= stable
INGRESS_MANIFEST = https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## --- Local app (no cluster) ---

.PHONY: install
install: ## Install app + dev dependencies
	pip install ".[dev]"

.PHONY: lint
lint: ## Run ruff lint + format check
	ruff check .
	ruff format --check .

.PHONY: test
test: ## Run unit tests
	pytest

.PHONY: run
run: ## Run the app locally on :8000
	APP_ENV=local uvicorn app.main:app --reload --port 8000

## --- Cluster lifecycle ---

.PHONY: cluster
cluster: ## Create the Kind cluster
	kind create cluster --config deploy/kind/cluster.yaml

.PHONY: ingress
ingress: ## Install NGINX ingress and wait for it
	kubectl apply -f $(INGRESS_MANIFEST)
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s

.PHONY: argocd
argocd: ## Install ArgoCD into the argocd namespace
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

.PHONY: bootstrap
bootstrap: ## Register the AppProject and the three Applications with ArgoCD
	kubectl apply -f deploy/argocd/project.yaml
	kubectl apply -f deploy/argocd/app-dev.yaml
	kubectl apply -f deploy/argocd/app-stage.yaml
	kubectl apply -f deploy/argocd/app-prod.yaml

.PHONY: demo
demo: cluster ingress argocd bootstrap ## Full local setup end-to-end
	@echo ""
	@echo "Setup complete. Next:"
	@echo "  make argocd-password   # get the ArgoCD admin password"
	@echo "  make argocd-ui         # port-forward the ArgoCD UI to :8080"
	@echo ""
	@echo "App URLs (once synced):"
	@echo "  http://dev.cicd-demo.localtest.me"
	@echo "  http://stage.cicd-demo.localtest.me"
	@echo "  http://prod.cicd-demo.localtest.me   (prod needs a manual sync)"

.PHONY: clean
clean: ## Delete the Kind cluster
	kind delete cluster --name $(CLUSTER)

## --- ArgoCD access ---

.PHONY: argocd-password
argocd-password: ## Print the initial ArgoCD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d; echo

.PHONY: argocd-ui
argocd-ui: ## Port-forward the ArgoCD UI to https://localhost:8080
	kubectl -n argocd port-forward svc/argocd-server 8080:443

## --- Promotion helpers (deliberate stage/prod advancement) ---
# Promote the exact image tag currently in one overlay to the next. This copies
# the already-built, scanned, dev-validated image forward — never rebuilds.

.PHONY: promote-stage
promote-stage: ## Copy dev's image tag into the stage overlay
	@tag=$$(grep 'newTag:' deploy/overlays/dev/kustomization.yaml | awk '{print $$2}'); \
	echo "Promoting $$tag -> stage"; \
	sed -i.bak "s/newTag:.*/newTag: $$tag/" deploy/overlays/stage/kustomization.yaml && \
	rm -f deploy/overlays/stage/kustomization.yaml.bak; \
	echo "Commit & push to let ArgoCD sync stage."

.PHONY: promote-prod
promote-prod: ## Copy stage's image tag into the prod overlay
	@tag=$$(grep 'newTag:' deploy/overlays/stage/kustomization.yaml | awk '{print $$2}'); \
	echo "Promoting $$tag -> prod"; \
	sed -i.bak "s/newTag:.*/newTag: $$tag/" deploy/overlays/prod/kustomization.yaml && \
	rm -f deploy/overlays/prod/kustomization.yaml.bak; \
	echo "Commit & push, then run a MANUAL sync: argocd app sync cicd-demo-prod"

## --- Manifest validation ---

.PHONY: validate
validate: ## Render all overlays with kustomize (catches manifest errors)
	@for env in dev stage prod; do \
		echo "== $$env =="; \
		kubectl kustomize deploy/overlays/$$env > /dev/null && echo "ok"; \
	done
