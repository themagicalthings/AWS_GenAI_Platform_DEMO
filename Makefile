TF := terraform -chdir=terraform
TFVARS := -var-file=dev.tfvars

.PHONY: init fmt validate lint plan apply ingest demo destroy test
init:    ; $(TF) init
fmt:     ; terraform fmt -recursive
validate:; $(TF) validate
lint:    ; tflint --chdir=terraform
plan:    ; $(TF) plan $(TFVARS)
apply:   ; $(TF) apply $(TFVARS) -auto-approve
ingest:  ; python scripts/ingest.py
demo:    ; bash scripts/deploy.sh && python scripts/ingest.py && python scripts/smoke_test.py
destroy: ; $(TF) destroy $(TFVARS) -auto-approve
test:    ; pytest
