TERRAFORM ?= terraform
API_URL ?= http://13.206.255.84
AWS_REGION ?= ap-south-1

.PHONY: terraform-init terraform-plan terraform-apply terraform-destroy smoke health status

terraform-init:
	cd infra/terraform && $(TERRAFORM) init

terraform-plan:
	cd infra/terraform && $(TERRAFORM) plan

terraform-apply:
	cd infra/terraform && $(TERRAFORM) apply

terraform-destroy:
	cd infra/terraform && $(TERRAFORM) destroy

health:
	curl -fsS "$(API_URL)/healthz"
	@printf "\n"

smoke:
	./scripts/smoke-test.sh "$(API_URL)"

status:
	aws ec2 describe-instances \
		--region "$(AWS_REGION)" \
		--filters Name=tag:Project,Values=alchemyst-devops \
		--query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Type:InstanceType,State:State.Name,PrivateIp:PrivateIpAddress,PublicIp:PublicIpAddress}' \
		--output table
