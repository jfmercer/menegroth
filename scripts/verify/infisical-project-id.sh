#!/usr/bin/env bash
# Print the ID of an Infisical project, looked up by slug as the `ci`
# machine identity (GitHub secrets INFISICAL_CLIENT_ID / _SECRET). The
# Verify workflow hands the CI/unlock project's ID to scripts/verify/server.sh
# for the key-custody check (D8). Credentials stay off argv: jq reads them
# from the environment, curl reads the token from a config on stdin.
#
# usage: infisical-project-id.sh <slug>
set -euo pipefail

: "${INFISICAL_CLIENT_ID:?}" "${INFISICAL_CLIENT_SECRET:?}"
API="${INFISICAL_API_URL:-https://eu.infisical.com}/api"

token="$(jq -n '{clientId: env.INFISICAL_CLIENT_ID, clientSecret: env.INFISICAL_CLIENT_SECRET}' |
  curl -sS --fail-with-body -H 'Content-Type: application/json' --data-binary @- \
    "$API/v1/auth/universal-auth/login" | jq -r .accessToken)"
[[ -n "$token" && "$token" != null ]] || { echo "infisical-project-id: login failed" >&2; exit 1; }

printf 'header = "Authorization: Bearer %s"\n' "$token" |
  curl -sS --fail-with-body -K- "$API/v1/projects/slug/$1" |
  jq -er '.id // .project.id // .workspace.id'
