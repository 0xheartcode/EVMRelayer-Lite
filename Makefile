
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
.PHONY: install
install: check-deps ## Install and build entire project from scratch - default target.
	@echo "$(GREEN)Installing and building entire project...$(NC)"
	@echo "$(YELLOW)Installing Foundry dependencies...$(NC)"
	@cd contracts && forge install
	@echo "$(YELLOW)Building contracts...$(NC)"
	@cd contracts && forge build
	@echo "$(YELLOW)Testing contracts...$(NC)"
	@cd contracts && forge test
	@echo "$(YELLOW)Installing relayer dependencies...$(NC)"
	@cd relayer && pnpm install --ignore-scripts
	@echo "$(YELLOW)Building relayer...$(NC)"
	@cd relayer && pnpm build
	@echo "$(GREEN)Project installation and build completed successfully!$(NC)"

.PHONY: setup
setup: deploy configure verify ## Run complete cross-chain setup (deploy + configure + verify).
	@echo "$(GREEN)Cross-chain messaging system setup completed!$(NC)"

# ================
##@ Smart Contracts - Development Commands

.PHONY: build
build: ## Compile contracts.
	@echo "$(GREEN)Building contracts...$(NC)"
	@cd contracts && forge build

.PHONY: clean
clean: ## Clean build artifacts.
	@echo "$(GREEN)Cleaning build artifacts...$(NC)"
	@cd contracts && forge clean

# ================
##@ Smart Contracts - Setup Commands

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
deploy: deploy-source deploy-dest ## Deploy contracts to both chains in sequence.
	@echo "$(GREEN)Deployed contracts to both chains!$(NC)"

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
##@ Smart Contracts - Testing Commands
.PHONY: test
test: ## Run all Foundry tests.
	@echo "$(GREEN)Running all tests...$(NC)"
	@cd contracts && forge test -vv

.PHONY: test-coverage
test-coverage: ## Generate test coverage report.
	@echo "$(GREEN)Generating test coverage report...$(NC)"
	@cd contracts && forge coverage --ir-minimum | rg "╭|File|=|╰|src/"

.PHONY: gas-report
gas-report: ## Generate gas usage report.
	@echo "$(GREEN)Generating gas report...$(NC)"
	@cd contracts && forge test --gas-report

# ================
##@ Smart Contracts - Message Testing Commands

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
##@ Smart Contracts - Anvil Management
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
##@ Relayer TS Commands

.PHONY: dockercompose-up
dockercompose-up: ## Start relayer with Docker Compose (build and logs).
	@echo "$(GREEN)Cleaning previous Docker containers...$(NC)"
	@$(MAKE) dockercompose-clean
	@echo "$(GREEN)Starting relayer with Docker Compose...$(NC)"
	export DOCKER_IMAGE_NAME=DOCKER_EVMRELAYER_LITE && \
	docker compose -p evmrelayer-lite -f relayer/utils/dockerfiles/docker-compose.yml up --build

.PHONY: dockercompose-up-d
dockercompose-up-detached: ## Start relayer with Docker Compose detached.
	@echo "$(GREEN)Cleaning previous Docker containers...$(NC)"
	@$(MAKE) dockercompose-clean
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

.PHONY: relayer-build
relayer-build: ## Build TypeScript relayer.
	@echo "$(GREEN)Building relayer...$(NC)"
	@cd relayer && pnpm build

.PHONY: relayer-dev
relayer-dev: ## Run relayer in watch mode for development.
	@echo "$(GREEN)Starting relayer in development mode...$(NC)"
	@cd relayer && pnpm dev

.PHONY: relayer-clean
relayer-clean: ## Clean relayer build artifacts.
	@echo "$(GREEN)Cleaning relayer build artifacts...$(NC)"
	@cd relayer && pnpm clean

.PHONY: relayer-start
relayer-start: ## Start built relayer.
	@echo "$(GREEN)Starting relayer...$(NC)"
	@cd relayer && pnpm start

# ================
##@ Utility Commands

.PHONY: reload-echo-env
reload-echo-env: ## Reload .env file and validate environment configuration.
	@echo ""
	@echo "$(GREEN)Reloading .env file...$(NC)"
	@echo "Chain One: $(call get_chain_config,one)"
	@echo "Chain Two: $(call get_chain_config,two)"
	@echo "Source Contract: $(SOURCE_CONTRACT)"
	@echo "Destination Contract: $(DEST_CONTRACT)"
	@echo "Relayer: $(RELAYER_ADDRESS)"

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

.PHONY: install-relayer
install-relayer: check-deps ## Install relayer dependencies only.
	@echo "Installing relayer dependencies..."
	@cd relayer && pnpm install --ignore-scripts
	@echo "$(GREEN)Relayer dependencies installed successfully!$(NC)"

# ================
##@ General Demo Commands

.PHONY: demo
demo: ## Complete end-to-end demo: start anvil, deploy, send message, run relayer, watch processing.
	@echo "$(GREEN)Starting Complete End-to-End Cross-Chain Demo$(NC)"
	@echo "================================================="
	@$(MAKE) demo-cleanup-silent || true
	@echo "$(YELLOW)Clearing relayer state for fresh start...$(NC)"
	@echo '{}' > relayer/relayer-state.json
	@$(MAKE) stop-anvil && $(MAKE) start-anvil
	@sleep 5
	@echo "$(YELLOW)Deploying and configuring contracts...$(NC)"
	@$(MAKE) setup
	@echo "$(YELLOW)Sending test message...$(NC)"
	@MESSAGE="Hello today we are Thursday 09 October" $(MAKE) demo-send-message
	@echo "$(YELLOW)Starting relayer backend...$(NC)"
	@$(MAKE) demo-run-relayer
	@echo "$(GREEN)End-to-end demo completed successfully!$(NC)"
	@$(MAKE) demo-cleanup

.PHONY: demo-custom-message
demo-custom-message: ## Send custom message and watch processing (use MESSAGE="your text").
	@if [ -z "$(MESSAGE)" ]; then \
		echo "$(RED)Error: MESSAGE variable not set. Use: MESSAGE='your text' make demo-custom-message$(NC)"; \
		exit 1; \
	fi
	@echo "$(GREEN)Custom Message Demo: $(MESSAGE)$(NC)"
	@echo "================================================="
	@$(MAKE) demo-cleanup-silent || true
	@echo "$(YELLOW)Clearing relayer state for fresh start...$(NC)"
	@echo '{}' > relayer/relayer-state.json
	@$(MAKE) start-anvil
	@sleep 5
	@echo "$(YELLOW)Deploying and configuring contracts...$(NC)"
	@$(MAKE) setup
	@echo "$(YELLOW)Sending custom message...$(NC)"
	@MESSAGE="$(MESSAGE)" $(MAKE) demo-send-message
	@echo "$(YELLOW)Starting relayer backend...$(NC)"
	@$(MAKE) demo-run-relayer
	@echo "$(GREEN)Custom message demo completed!$(NC)"
	@$(MAKE) demo-cleanup

.PHONY: demo-send-message
demo-send-message: ## Send test message and capture block info.
	@$(call check_env_var,RPC_URL_ONE)
	@$(call check_env_var,SOURCE_CONTRACT)
	@$(call check_env_var,DEST_CONTRACT)
	@$(call check_env_var,USER_PRIVATE_KEY)
	@echo "$(GREEN)Sending cross-chain message...$(NC)"
	@cd contracts && forge script script/integration/SendMessageScript.s.sol --rpc-url $(RPC_URL_ONE) --broadcast -vvv
	@echo "$(GREEN)Message sent!$(NC)"

.PHONY: demo-run-relayer
demo-run-relayer: ## Build and run relayer, monitor for 3-phase completion.
	@echo "$(GREEN)Building relayer backend...$(NC)"
	@cd relayer && pnpm build
	@echo "$(GREEN)Starting relayer and monitoring for message processing...$(NC)"
	@echo "$(YELLOW)Watching for Phase 1 (claimBlock), Phase 2 (executeMessage), Phase 3 (confirmBlockDelivery)$(NC)"
	@echo ""
	@cd relayer && \
	node dist/index.js 2>&1 | while read line; do \
		echo "$$line"; \
		if echo "$$line" | grep -q "Web3 Call: claimBlock"; then \
			echo "PHASE 1 DETECTED: Block claimed!"; \
		elif echo "$$line" | grep -q "Web3 Call: executeMessage"; then \
			echo "PHASE 2 DETECTED: Message executed on destination!"; \
		elif echo "$$line" | grep -q "✅ PHASE 3 COMPLETE"; then \
			echo "PHASE 3 DETECTED: Delivery proof submitted!"; \
			echo "Waiting 7 seconds to let logs settle..."; \
			sleep 7; \
			echo ""; \
			echo "The demo worked properly, here is all that we have done:"; \
			echo ""; \
			echo "📋 Demo Summary:"; \
			echo "  ✅ Started Anvil instances (Chain 31337 & 31338)"; \
			echo "  ✅ Deployed CrossChain contracts to both chains"; \
			echo "  ✅ Configured relayer permissions"; \
			echo "  ✅ Verified contract setup"; \
			echo "  ✅ Sent cross-chain message: Hello today we are Thursday 09 October"; \
			echo "  ✅ Built and started relayer backend"; \
			echo "  ✅ PHASE 1: Claimed block and picked up transaction"; \
			echo "  ✅ PHASE 2: Executed message on destination chain"; \
			echo "  ✅ PHASE 3: Submitted delivery proof back to source chain"; \
			echo ""; \
			echo "🎉 3-Phase Cross-Chain Protocol completed successfully!"; \
			echo ""; \
			echo "\\o.o/ You have arrived at the end of this script!"; \
			sleep 3; \
			pkill -f "node dist/index.js" || true; \
			exit 0; \
		fi; \
	done
	@pkill -f "node dist/index.js" || true
	@echo "$(GREEN)Relayer monitoring completed.$(NC)"

.PHONY: demo-cleanup
demo-cleanup: ## Stop all demo processes and clean up.
	@echo "$(YELLOW)Cleaning up demo processes...$(NC)"
	@pkill -f "node dist/index.js" || echo "  No relayer processes running"
	@pkill anvil || echo "  No anvil processes running"
	@echo "$(GREEN)Cleanup completed$(NC)"

.PHONY: demo-docker
demo-docker: ## Complete end-to-end demo using Docker: start anvil, deploy, send message, run relayer in Docker, watch processing.
	@echo "$(GREEN)Starting Complete End-to-End Cross-Chain Demo with Docker$(NC)"
	@echo "========================================================="
	@$(MAKE) demo-cleanup-silent || true
	@echo "$(YELLOW)Manually cleaning Docker to ensure fresh start...$(NC)"
	@$(MAKE) dockercompose-clean || true
	@echo "$(YELLOW)Clearing relayer state for fresh start...$(NC)"
	@echo '{}' > relayer/relayer-state.json
	@$(MAKE) stop-anvil && $(MAKE) start-anvil
	@sleep 5
	@echo "$(YELLOW)Deploying and configuring contracts...$(NC)"
	@$(MAKE) setup
	@echo "$(YELLOW)Sending test message...$(NC)"
	@MESSAGE="Hello today we are Thursday 09 October" $(MAKE) demo-send-message
	@echo "$(YELLOW)Starting relayer in Docker and monitoring for completion...$(NC)"
	@echo "$(YELLOW)Watching for Phase 1 (claimBlock), Phase 2 (executeMessage), Phase 3 (confirmBlockDelivery)$(NC)"
	@echo ""
	@export DOCKER_IMAGE_NAME=DOCKER_EVMRELAYER_LITE && \
	timeout 120 docker compose -p evmrelayer-lite -f relayer/utils/dockerfiles/docker-compose.yml up --build 2>&1 | while read line; do \
		echo "$$line"; \
		if echo "$$line" | grep -q "✅ PHASE 3 COMPLETE"; then \
			echo "\\o.o/ GREP HIT DETECTED! confirmBlockDelivery found!"; \
			echo "PHASE 3 COMPLETED - STOPPING"; \
			echo "Waiting 7 seconds to let logs settle..."; \
			sleep 7; \
			echo ""; \
			echo "The demo worked properly, here is all that we have done:"; \
			echo ""; \
			echo "📋 Demo Summary:"; \
			echo "  ✅ Started Anvil instances (Chain 31337 & 31338)"; \
			echo "  ✅ Deployed CrossChain contracts to both chains"; \
			echo "  ✅ Configured relayer permissions"; \
			echo "  ✅ Verified contract setup"; \
			echo "  ✅ Sent cross-chain message: Hello today we are Thursday 09 October"; \
			echo "  ✅ Started relayer in Docker container"; \
			echo "  ✅ PHASE 1: Claimed block and picked up transaction"; \
			echo "  ✅ PHASE 2: Executed message on destination chain"; \
			echo "  ✅ PHASE 3: Submitted delivery proof back to source chain"; \
			echo ""; \
			echo "🎉 3-Phase Cross-Chain Protocol completed successfully!"; \
			echo ""; \
			echo "\\o.o/ You have arrived at the end of this script!"; \
			docker compose -p evmrelayer-lite -f relayer/utils/dockerfiles/docker-compose.yml down; \
			break; \
		fi; \
	done
	@echo "$(YELLOW)🧹 Cleaning up processes...$(NC)"
	@$(MAKE) dockercompose-clean && $(MAKE) stop-anvil && echo "$(GREEN)✅ All processes stopped gracefully$(NC)" 
	@echo "$(GREEN)Docker demo completed successfully!$(NC)"

.PHONY: demo-cleanup-silent
demo-cleanup-silent: ## Silent cleanup for internal use.
	@pkill -f "node dist/index.js" 2>/dev/null || true
	@pkill anvil 2>/dev/null || true
	@$(MAKE) dockercompose-clean 2>/dev/null || true

