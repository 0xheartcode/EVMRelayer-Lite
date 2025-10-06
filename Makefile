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

# Check if dependencies are installed
PNPM_EXISTS := $(shell which pnpm)
DOCKER_EXISTS := $(shell which docker)
ANVIL_EXISTS := $(shell which anvil)
IN_DOCKER := $(shell if [ -f /.dockerenv ]; then echo "1"; else echo "0"; fi)

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
##@ Message Testing Commands

.PHONY: send-message
send-message: ## Send a test message from Chain One to Chain Two.
	@$(call check_env_var,RPC_URL_ONE)
	@$(call check_env_var,SOURCE_CONTRACT)
	@$(call check_env_var,DEST_CONTRACT)
	@$(call check_env_var,USER_PRIVATE_KEY)
	@echo "$(GREEN)Sending test message from Chain One...$(NC)"
	@cd contracts && forge script script/integration/SendMessageScript.s.sol --rpc-url $(RPC_URL_ONE) --broadcast -vvv

.PHONY: send-custom-message
send-custom-message: ## Send a custom message (use MESSAGE="your text" make send-custom-message).
	@$(call check_env_var,RPC_URL_ONE)
	@$(call check_env_var,SOURCE_CONTRACT)
	@$(call check_env_var,DEST_CONTRACT)
	@$(call check_env_var,USER_PRIVATE_KEY)
	@if [ -z "$(MESSAGE)" ]; then \
		echo "$(RED)Error: MESSAGE variable not set. Use: MESSAGE='your text' make send-custom-message$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)Sending custom message: $(MESSAGE)$(NC)"
	@cd contracts && MESSAGE="$(MESSAGE)" forge script script/integration/SendMessageScript.s.sol --rpc-url $(RPC_URL_ONE) --broadcast -vvv

# ================
##@ Dependencies
.PHONY: check-deps
check-deps: ## Verify required system dependencies are installed.
	@echo "Checking dependencies..."
	@if [ -z "$(PNPM_EXISTS)" ]; then \
		echo "❌ pnpm is not installed. Please install pnpm first."; \
		exit 1; \
	else \
		echo "✓ pnpm found"; \
	fi
	@if [ "$(IN_DOCKER)" = "0" ]; then \
		if [ -z "$(DOCKER_EXISTS)" ]; then \
			echo "❌ docker is not installed. Please install docker first."; \
			exit 1; \
		else \
			echo "✓ docker found"; \
		fi; \
	fi
	@if [ -z "$(ANVIL_EXISTS)" ]; then \
		echo "❌ anvil is not installed. Please install foundry first."; \
		exit 1; \
	else \
		echo "✓ anvil found"; \
	fi
	@echo "✨ All dependencies are satisfied"

.PHONY: install
install: check-deps ## Install project dependencies using pnpm.
	@echo "Installing dependencies..."
	@cd relayer && pnpm install --ignore-scripts
	@echo "$(GREEN)Dependencies installed successfully!$(NC)"

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

# ================
##@ Service Management
.PHONY: start-anvil
start-anvil: check-deps ## Start Anvil instances for all configured networks.
	@if [ -f contracts/.env ]; then \
		set -a && . contracts/.env && set +a; \
	else \
		echo "❌ Error: contracts/.env file not found. Please create it first."; \
		exit 1; \
	fi; \
	echo "$(GREEN)Starting Anvil instances for configured networks...$(NC)"; \
	networks=$$(echo $$NETWORKS | tr ',' ' '); \
	for network in $$networks; do \
		$(MAKE) start-anvil-network NETWORK_NAME=$$network; \
	done

.PHONY: start-anvil-network
start-anvil-network: ## Start single Anvil instance for specified network.
	@network=$(NETWORK_NAME); \
	network_upper=$$(echo $$network | tr '[:lower:]' '[:upper:]'); \
	rpc_url_var="RPC_URL_$$network_upper"; \
	port_var="ANVIL_PORT_$$network_upper"; \
	chain_id_var="CHAIN_ID_$$network_upper"; \
	rpc_url=$$(printenv $$rpc_url_var); \
	port=$$(printenv $$port_var); \
	chain_id=$$(printenv $$chain_id_var); \
	echo "$(YELLOW)Starting Anvil for $$network network (port: $$port, chain-id: $$chain_id)$(NC)"; \
	if [ -n "$$rpc_url" ] && [ "$$rpc_url" != "localhost" ] && [ "$$rpc_url" != "http://localhost:$$port" ]; then \
		echo "  Forking from: $$rpc_url"; \
		ANVIL_CMD="anvil --fork-url $$rpc_url --host 0.0.0.0 --port $$port --block-time $${RPC_BLOCK_TIME:-2} --chain-id $$chain_id"; \
	else \
		echo "  Running as local chain (no fork)"; \
		ANVIL_CMD="anvil --host 0.0.0.0 --port $$port --block-time $${RPC_BLOCK_TIME:-2} --chain-id $$chain_id"; \
	fi; \
	if [ "$$(uname)" = "Linux" ]; then \
		gnome-terminal -- bash -c "$$ANVIL_CMD; exec bash"; \
	elif [ "$$(uname)" = "Darwin" ]; then \
		osascript -e "tell app \"Terminal\" to do script \"$$ANVIL_CMD\""; \
	else \
		echo "$(RED)Unsupported OS: Please run anvil manually for $$network$(NC)"; \
		exit 1; \
	fi; \
	sleep 2


.PHONY: stop-anvil
stop-anvil: ## Stop all running Anvil instances.
	@echo "$(YELLOW)Stopping all Anvil instances...$(NC)"
	@pkill anvil || echo "No Anvil instances were running"
	@echo "$(GREEN)✅ Anvil instances stopped$(NC)"

# ================
##@ Docker Commands

.PHONY: dockercompose-up
dockercompose-up: ## Start relayer with Docker Compose (build and logs).
	@echo "$(GREEN)Starting relayer with Docker Compose...$(NC)"
	export DOCKER_IMAGE_NAME=DOCKER_EVMRELAYER_LITE && \
	docker compose -p evmrelayer-lite -f relayer/utils/dockerfiles/docker-compose.yml up --build

.PHONY: dockercompose-up-d
dockercompose-up-detached: ## Start relayer with Docker Compose detached.
	@echo "$(GREEN)Starting relayer with Docker Compose...$(NC)"
	export DOCKER_IMAGE_NAME=DOCKER_EVMRELAYER_LITE && \
	docker compose -p evmrelayer-lite -f relayer/utils/dockerfiles/docker-compose.yml up --build -d

.PHONY: dockercompose-down
dockercompose-down: ## Stop and remove relayer Docker containers.
	@echo "$(YELLOW)Stopping relayer Docker containers...$(NC)"
	docker compose -p evmrelayer-lite -f relayer/utils/dockerfiles/docker-compose.yml down

.PHONY: dockercompose-logs
dockercompose-logs: ## Show relayer Docker logs.
	docker compose -p evmrelayer-lite -f relayer/utils/dockerfiles/docker-compose.yml logs -f relayer

.PHONY: dockercompose-clean
dockercompose-clean: ## Clean Docker containers, volumes and images.
	@echo "$(YELLOW)Cleaning Docker containers, volumes and images...$(NC)"
	docker compose -p evmrelayer-lite -f relayer/utils/dockerfiles/docker-compose.yml down -v --rmi all

# ================
##@ Utility Commands

.PHONY: gas-report
gas-report: ## Generate gas usage report.
	@echo "$(GREEN)Generating gas report...$(NC)"
	@cd contracts && forge test --gas-report

.PHONY: test-coverage
test-coverage: ## Generate test coverage report.
	@echo "$(GREEN)Generating test coverage report...$(NC)"
	@cd contracts && forge coverage --ir-minimum | rg "╭|File|=|╰|src/"

.PHONY: reload-echo-env
reload-echo-env: ## Reload .env file and validate environment configuration.
	@echo ""
	@echo "$(GREEN)Reloading .env file...$(NC)"
	@echo "Chain One: $(call get_chain_config,one)"
	@echo "Chain Two: $(call get_chain_config,two)"
	@echo "Source Contract: $(SOURCE_CONTRACT)"
	@echo "Destination Contract: $(DEST_CONTRACT)"
	@echo "Relayer: $(RELAYER_ADDRESS)"

