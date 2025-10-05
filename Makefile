# Load environment variables
-include contracts/.env

# Colors for output
GREEN := \033[0;32m
YELLOW := \033[0;33m
RED := \033[0;31m
NC := \033[0m # No Color

# Function to check if env var is set
define check_env_var
$(if $($(1)),,$(error $(1) is not set in contracts/.env file))
endef

# Function to get chain configuration
define get_chain_config
$(shell chain="$(1)"; \
        if [ "$chain" = "one" ]; then \
            echo "$(CHAIN_ID_ONE) - $(RPC_URL_ONE)"; \
        elif [ "$chain" = "two" ]; then \
            echo "$(CHAIN_ID_TWO) - $(RPC_URL_TWO)"; \
        else \
            echo "Unknown chain"; \
        fi)
endef

# Function to validate deployment readiness
define check_deployment_readiness
$(shell if [ -z "$(SOURCE_CONTRACT)" ] && [ "$(1)" = "dest" ]; then \
            echo "false"; \
        else \
            echo "true"; \
        fi)
endef

# ================
##@ Help
.PHONY: help
help:  ## Display this help message with target descriptions.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

# ================
##@ Default Target
.PHONY: setup
setup: deploy configure verify ## Run complete cross-chain setup (deploy + configure + verify) - default target.
	@echo "$(GREEN)Cross-chain messaging system setup completed!$(NC)"

# ================
##@ Deployment Commands

.PHONY: deploy-source
deploy-source: ## Deploy CrossChainSource contract to Chain One.
	@$(call check_env_var,RPC_URL_ONE)
	@$(call check_env_var,CHAIN_ID_ONE)
	@echo "$(GREEN)Deploying to Chain One (Source)...$(NC)"
	@cd contracts && forge script script/setup/Deploy.s.sol --rpc-url $(RPC_URL_ONE) --broadcast -vvv

.PHONY: deploy-dest
deploy-dest: ## Deploy CrossChainDestination contract to Chain Two.
	@$(call check_env_var,RPC_URL_TWO)
	@$(call check_env_var,CHAIN_ID_TWO)
	@$(call check_env_var,SOURCE_CONTRACT)
	@echo "$(GREEN)Deploying to Chain Two (Destination)...$(NC)"
	@cd contracts && forge script script/setup/Deploy.s.sol --rpc-url $(RPC_URL_TWO) --broadcast -vvv

.PHONY: deploy
deploy: deploy-source ## Deploy contracts to both chains in sequence.
	@echo "$(YELLOW)Source deployed! Update contracts/.env with SOURCE_CONTRACT address, then run 'make deploy-dest'$(NC)"

# ================
##@ Configuration Commands

.PHONY: configure-source
configure-source: ## Configure relayer roles on Chain One (Source).
	@$(call check_env_var,RPC_URL_ONE)
	@$(call check_env_var,SOURCE_CONTRACT)
	@$(call check_env_var,RELAYER_ADDRESS)
	@echo "$(GREEN)Configuring Chain One (Source)...$(NC)"
	@cd contracts && forge script script/setup/Configure.s.sol --rpc-url $(RPC_URL_ONE) --broadcast -vvv

.PHONY: configure-dest
configure-dest: ## Configure relayer roles on Chain Two (Destination).
	@$(call check_env_var,RPC_URL_TWO)
	@$(call check_env_var,DEST_CONTRACT)
	@$(call check_env_var,RELAYER_ADDRESS)
	@echo "$(GREEN)Configuring Chain Two (Destination)...$(NC)"
	@cd contracts && forge script script/setup/Configure.s.sol --rpc-url $(RPC_URL_TWO) --broadcast -vvv

.PHONY: configure  
configure: configure-source configure-dest ## Configure relayer roles on both chains.
	@echo "$(GREEN)Configured both chains!$(NC)"

# ================
##@ Verification Commands

.PHONY: verify-source
verify-source: ## Run verification checks on Chain One (Source).
	@$(call check_env_var,RPC_URL_ONE)
	@$(call check_env_var,SOURCE_CONTRACT)
	@echo "$(GREEN)Verifying Chain One (Source)...$(NC)"
	@cd contracts && forge script script/integration/Verify.s.sol --rpc-url $(RPC_URL_ONE) -vvv

.PHONY: verify-dest
verify-dest: ## Run verification checks on Chain Two (Destination).
	@$(call check_env_var,RPC_URL_TWO)
	@$(call check_env_var,DEST_CONTRACT)
	@echo "$(GREEN)Verifying Chain Two (Destination)...$(NC)"
	@cd contracts && forge script script/integration/Verify.s.sol --rpc-url $(RPC_URL_TWO) -vvv

.PHONY: verify
verify: verify-source verify-dest ## Run verification checks on both chains.
	@echo "$(GREEN)Verified both chains!$(NC)"

# ================
##@ Testing Commands

.PHONY: test
test: ## Run all Foundry tests.
	@echo "$(GREEN)Running all tests...$(NC)"
	@cd contracts && forge test -vv

# ================
##@ Development Commands

.PHONY: build
build: ## Compile contracts.
	@echo "$(GREEN)Building contracts...$(NC)"
	@cd contracts && forge build

.PHONY: clean
clean: ## Clean build artifacts.
	@echo "$(GREEN)Cleaning build artifacts...$(NC)"
	@cd contracts && forge clean

.PHONY: fmt
fmt: ## Format code.
	@echo "$(GREEN)Formatting code...$(NC)"
	@cd contracts && forge fmt

.PHONY: anvil
anvil: ## Start local Anvil node for testing.
	@echo "$(GREEN)Starting local Anvil node...$(NC)"
	@anvil --host 0.0.0.0 --chain-id 31337

# ================
##@ Utility Commands

.PHONY: gas-report
gas-report: ## Generate gas usage report.
	@echo "$(GREEN)Generating gas report...$(NC)"
	@cd contracts && forge test --gas-report

.PHONY: reload-echo-env
reload-echo-env: ## Reload .env file and validate environment configuration.
	@echo ""
	@echo "$(GREEN)Reloading .env file...$(NC)"
	@echo "Chain One: $(call get_chain_config,one)"
	@echo "Chain Two: $(call get_chain_config,two)"
	@echo "Source Contract: $(SOURCE_CONTRACT)"
	@echo "Destination Contract: $(DEST_CONTRACT)"
	@echo "Relayer: $(RELAYER_ADDRESS)"

