TF := terraform -chdir=terraform
TFVARS := -var-file=dev.tfvars

.PHONY: init fmt fmt-check validate lint plan apply ingest demo destroy test test-tf test-py
init:    ; $(TF) init
fmt:     ; terraform fmt -recursive
fmt-check:; terraform fmt -check -recursive
validate:; $(TF) validate
lint:    ; tflint --chdir=terraform
plan:    ; $(TF) plan $(TFVARS)
apply:   ; $(TF) apply $(TFVARS) -auto-approve
ingest:  ; python scripts/ingest.py
demo:    ; bash scripts/deploy.sh && python scripts/ingest.py && python scripts/smoke_test.py
destroy: ; $(TF) destroy $(TFVARS) -auto-approve
test-tf: ; bash scripts/run_tf_tests.sh
test-py: ; pytest
test:    test-tf test-py
