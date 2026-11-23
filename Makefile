.PHONY: all fmt validate tflint checkov clean

all: fmt validate tflint checkov

fmt:
	@echo "==> Running terraform fmt..."
	terraform fmt -recursive

validate:
	@echo "==> Running terraform validate across environments..."
	@for env in environments/perf-opt; do \
		if [ -d "$$env" ]; then \
			echo "Validating $$env..."; \
			cd $$env && terraform init -backend=false && terraform validate && cd - > /dev/null; \
		fi; \
	done

tflint:
	@echo "==> Running tflint..."
	tflint --recursive

checkov:
	@echo "==> Running checkov security scan..."
	checkov -d . --framework terraform --skip-check CKV_TF_1,CKV_AWS_145 --quiet
