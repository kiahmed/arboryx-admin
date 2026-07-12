# Arboryx Admin operator targets. Thin wrappers over the deploy/admin scripts.
# Run `make` (or `make help`) for the list. Knobs are shown in orange.
.DEFAULT_GOAL := help
.PHONY: help \
        api-deploy api-update api-cold-start api-local \
        ui-deploy ui-local \
        frontend-config frontend-gcs frontend-firebase \
        rotator-setup rotator-deploy reminder-setup reminder-deploy \
        user-create user-rotate user-list user-get user-delete \
        rotate-key list-secrets sync-firestore dev-setup \
        test test-auth test-api test-ui test-ui-live test-frontend \
        build clean \
        worktree-clean _notmain commit push pr ship

# ---- colors --------------------------------------------------------------
C_CYAN   := \033[36m
C_ORANGE := \033[38;5;208m
C_DIM    := \033[2m
C_OFF    := \033[0m

# ---- typo guard: reject unknown KEY=val on the command line --------------
# Any command-line variable not in this allowlist aborts, so `make user-get
# USR=x` fails loudly instead of silently doing the wrong thing.
KNOWN_VARS := USER KIND FULL DRY FORCE PORT m
_cmdline_vars := $(foreach kv,$(MAKEOVERRIDES),$(firstword $(subst =, ,$(kv))))
_unknown_vars := $(filter-out $(KNOWN_VARS),$(_cmdline_vars))
ifneq ($(_unknown_vars),)
$(error unknown option(s): $(_unknown_vars) — valid knobs: $(KNOWN_VARS))
endif

# ---- flag helpers (KEY=1 -> --flag) --------------------------------------
_DRY   := $(if $(DRY),--dry-run)
_FULL  := $(if $(FULL),--full)
PORT   ?= 8000
SA     := dev-utils/service_account.json

# ==========================================================================
#  API backend (Cloud Function: arboryx-admin-api)
# ==========================================================================
api-deploy:       ## Deploy the API backend (auto update-vs-full) [FULL=1] [DRY=1]
	bash cloud_function/deploy.sh $(_FULL) $(_DRY)

api-update:       ## Fast code-only update of the API backend
	bash cloud_function/update.sh

api-cold-start:   ## Force a cold start (evict cached keys / warm instances)
	bash dev-utils/cold_start_function.sh

api-local:        ## Serve the API backend locally via functions-framework [PORT=8000]
	@test -f $(SA) && export GOOGLE_APPLICATION_CREDENTIALS=$(PWD)/$(SA) || true; \
	 functions-framework --target=api_handler --source=cloud_function/main.py --port=$(PORT)

# ==========================================================================
#  Admin dashboard UI (arborist_*.html on GCS)
# ==========================================================================
ui-deploy:        ## Deploy the admin UI to GCS (login-gated, no key) [DRY=1]
	bash deploy_arboryx-admin.sh $(_DRY)

ui-local:         ## Serve the admin UI locally with API_URL injected [PORT=8000]
	@set -a; . ./arboryx_admin_ui.config; set +a; \
	 mkdir -p dist; \
	 sed "s|__ARBORYX_ADMIN_API_URL__|$$API_URL|g" "$$UI_FILE" > "dist/$$UI_FILE"; \
	 echo "→ http://localhost:$(PORT)/$$UI_FILE  (Ctrl-C to stop)"; \
	 cd dist && exec python3 -m http.server $(PORT)

# ==========================================================================
#  Public landing page (frontend/)
# ==========================================================================
frontend-config:   ## Regenerate frontend/scripts/config.js locally (no upload)
	bash frontend/deploy.sh --local

frontend-gcs:      ## Deploy the public landing page to GCS [DRY=1]
	bash frontend/deploy.sh --gcs $(_DRY)

frontend-firebase: ## Deploy the public landing page to Firebase Hosting [DRY=1]
	bash frontend/deploy.sh --firebase $(_DRY)

# ==========================================================================
#  Key rotator + rotation reminder (quarterly Cloud Functions)
# ==========================================================================
rotator-setup:    ## One-time: create rotator service account + IAM
	bash cloud_function_rotator/make_rotator_pipeline_ready.sh

rotator-deploy:   ## Deploy the quarterly admin-key rotator [DRY=1]
	bash cloud_function_rotator/deploy.sh $(_DRY)

reminder-setup:   ## One-time: create reminder service account + IAM
	bash cloud_function_reminder/make_reminder_pipeline_ready.sh

reminder-deploy:  ## Deploy the quarterly rotation-reminder emailer [DRY=1]
	bash cloud_function_reminder/deploy.sh $(_DRY)

# ==========================================================================
#  Admin tasks — login users, key rotation, secrets
# ==========================================================================
user-create:      ## Create an admin login user (strong pw) [USER=name]
	bash dev-utils/manage_admin_users.sh create $(USER)

user-rotate:      ## Rotate a user's password [USER=name]
	bash dev-utils/manage_admin_users.sh rotate $(USER)

user-list:        ## List admin users + passwords (plaintext, from Secret Manager)
	bash dev-utils/manage_admin_users.sh list

user-get:         ## Show one user's password (USER=name)
	@test -n "$(USER)" || { echo 'usage: make user-get USER=name'; exit 2; }
	bash dev-utils/manage_admin_users.sh get $(USER)

user-delete:      ## Delete an admin user (USER=name)
	@test -n "$(USER)" || { echo 'usage: make user-delete USER=name'; exit 2; }
	bash dev-utils/manage_admin_users.sh delete $(USER)

rotate-key:       ## Rotate an API key (KIND=public|admin|smtp) [DRY=1]
	@test -n "$(KIND)" || { echo 'usage: make rotate-key KIND=public|admin|smtp'; exit 2; }
	bash dev-utils/rotate_key.sh $(KIND) $(_DRY)

list-secrets:     ## List the project's Secret Manager secrets
	bash dev-utils/list_secrets.sh

sync-firestore:   ## Mirror the GCS findings log into Firestore
	python3 dev-utils/sync_gcs_to_firestore.py

dev-setup:        ## One-time local dev environment setup
	bash dev-utils/make_dev_env_ready.sh

# ==========================================================================
#  Tests
# ==========================================================================
test:             ## Run the safe local suite (auth + UI render)
	@$(MAKE) --no-print-directory test-auth
	@$(MAKE) --no-print-directory test-ui

test-auth:        ## Admin auth end-to-end suite (real Firestore + Secret Manager)
	python3 dev-utils/test_admin_auth.py

test-api:         ## Deployed-API suite (needs ARBORYX_ADMIN_API_URL / _API_KEY env)
	python3 dev-utils/test_api.py --suite all

test-ui:          ## Headless admin-UI render smoke test
	node dev-utils/test_ui_render.js

test-ui-live:     ## Admin UI end-to-end against the live API
	node dev-utils/test_ui_live.js

test-frontend:    ## Public landing-page render test
	node dev-utils/test_frontend_landing.js

# ==========================================================================
#  Build / cleanup
# ==========================================================================
build:            ## Validate everything (bash -n, py_compile, node --check) — no-build static app
	@echo "validating shell scripts..."; \
	 for s in $$(git ls-files '*.sh'); do bash -n "$$s" && echo "  ok  $$s" || exit 1; done
	@echo "compiling python..."; \
	 python3 -m py_compile cloud_function/main.py $$(git ls-files 'dev-utils/*.py') && echo "  ok  python"
	@echo "checking admin-UI inline JS..."; \
	 f="$$(. ./arboryx_admin_ui.config 2>/dev/null; echo $${UI_FILE:-arborist_3.5.html})"; \
	 d="$$(mktemp -d)"; tmp="$$d/uicheck.js"; \
	 python3 -c "import re;src=open('$$f').read();m=re.search(r'<script>(.*)</script>',src,re.S);open('$$tmp','w').write(m.group(1))" \
	   && node --check "$$tmp" && echo "  ok  $$f inline JS"; rm -rf "$$d"

clean:            ## Remove build artifacts + caches (dist/, __pycache__, *.pyc)
	rm -rf dist
	find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name '*.pyc' -delete 2>/dev/null || true
	@echo "cleaned (config *.bak backups left in place)"

# ==========================================================================
#  Worktree cleanup
# ==========================================================================
worktree-clean:   ## Remove MERGED worktrees everywhere [name] [FORCE=1]
	@bash dev-utils/worktree-clean.sh "$(filter-out $@,$(MAKECMDGOALS))" "FORCE=$(FORCE)"

# Let the worktree name be positional (`make worktree-clean <name>`): turn the
# trailing name into a no-op goal. Scoped to worktree-clean so it never masks
# typos in other targets.
ifeq (worktree-clean,$(firstword $(MAKECMDGOALS)))
$(if $(filter-out worktree-clean,$(MAKECMDGOALS)),\
     $(eval $(filter-out worktree-clean,$(MAKECMDGOALS)):;@:))
endif

# ==========================================================================
#  Git workflow (run inside a worktree branch, never on main)
# ==========================================================================
_notmain:
	@test "$$(git rev-parse --abbrev-ref HEAD)" != main \
	  || { echo "refusing: you're on main — switch to a worktree branch"; exit 1; }

commit push pr ship: _notmain

commit:           ## Stage all + commit (m="message")
	@test -n "$(m)" || { echo 'usage: make commit m="message"'; exit 2; }
	git add -A && git commit -m "$(m)"

push:             ## Push the current branch to origin (sets upstream)
	git push -u origin $$(git rev-parse --abbrev-ref HEAD)

pr:               ## Open a draft PR from the current branch (auto-filled)
	gh pr create --draft --fill --base main --head $$(git rev-parse --abbrev-ref HEAD)

ship:             ## commit + push + draft PR in one (m="message")
	@test -n "$(m)" || { echo 'usage: make ship m="message"'; exit 2; }
	git add -A && git commit -m "$(m)"
	git push -u origin $$(git rev-parse --abbrev-ref HEAD)
	gh pr create --draft --fill --base main --head $$(git rev-parse --abbrev-ref HEAD)

# ==========================================================================
#  Help
# ==========================================================================
help:             ## Show this list
	@echo "Arboryx Admin — operator targets:"
	@grep -E '^[a-zA-Z][a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "} { \
	      desc=$$2; \
	      gsub(/\[[^]]*\]/, "$(C_ORANGE)&$(C_OFF)", desc); \
	      gsub(/\([A-Za-z_]+=[^)]*\)/, "$(C_ORANGE)&$(C_OFF)", desc); \
	      printf "  $(C_CYAN)%-18s$(C_OFF) %s\n", $$1, desc; \
	  }'
	@printf "  $(C_DIM)knobs:$(C_OFF) $(C_ORANGE)%s$(C_OFF)\n" "$(KNOWN_VARS)"
