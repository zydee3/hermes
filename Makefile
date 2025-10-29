.PHONY: help db-up db-down db-logs db-shell db-reset

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

## Start the database
db-up:
	docker compose up -d

## Stop the database
db-down:
	docker compose down

## Reset database (deletes all data)
db-reset: 
	docker compose down -v
	docker compose up -d
