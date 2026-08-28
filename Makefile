# Thin wrapper around docker compose: Compose has no pre-start hook, so the
# Duo reminder and the "did it actually connect?" wait live here.
COMPOSE := docker compose
CONTAINER := cornell-vpn

.PHONY: up down logs status ssh rebuild

up:
	@printf '\n  ============================================================\n'
	@printf '     Starting CU VPN - APPROVE THE DUO PUSH ON YOUR PHONE\n'
	@printf '  ============================================================\n\n'
	@$(COMPOSE) up -d
	@printf '  waiting for the tunnel'
	@for i in $$(seq 1 60); do \
		if docker exec $(CONTAINER) ip link show tun0 >/dev/null 2>&1; then \
			printf '\n\n  connected: '; \
			docker exec $(CONTAINER) ip -4 -o addr show tun0 | awk '{print $$4}'; \
			printf '  ssh cornell-ece    is ready to use\n\n'; \
			exit 0; \
		fi; \
		if [ -z "$$(docker ps -q -f name=$(CONTAINER))" ]; then \
			printf '\n\n  container is not running - last log lines:\n\n'; \
			$(COMPOSE) logs --tail=15; \
			exit 1; \
		fi; \
		printf '.'; sleep 2; \
	done; \
	printf '\n\n  timed out. Was the Duo push approved? Recent logs:\n\n'; \
	$(COMPOSE) logs --tail=15; exit 1

# Pick up Dockerfile/entry.sh changes (needs a fresh Duo approval).
rebuild:
	@$(COMPOSE) build
	@$(MAKE) up

down:
	@$(COMPOSE) down

logs:
	@$(COMPOSE) logs -f

status:
	@$(COMPOSE) ps
	@docker exec $(CONTAINER) ip -4 -o addr show tun0 2>/dev/null | awk '{print "  tun0: "$$4}' \
		|| echo "  tunnel is down"

ssh:
	@ssh cornell-ece
