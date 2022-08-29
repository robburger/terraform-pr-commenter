#!/bin/bash
set -x

ACCEPT_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GH_TOKEN"
CONTENT_HEADER="Content-Type: application/json"

PR_COMMENTS_URL="https://api.github.com/repos/GetTerminus/eks-observability-infra/issues/4/comments"
PR_COMMENT_URI="https://api.github.com/repos/GetTerminus/eks-observability-infra/issues/comments/4"

test () {

  local link_header
  local link_header_next_rel
  local last_page
  local page
  local last_page=1

  local jq='.[] | select(.body|test ("'
  jq+=$regex
  jq+='")) | .id'

  echo "Checking comment page count."

  link_header=$(curl -sSI -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L "$PR_COMMENTS_URL" | grep -i ^link)

  # if I find a matching link header...
  if echo "$link_header" | grep -Fi 'rel="next"'; then
    # we found a next page -> find the last page
    IFS=',' read -ra links <<< "$link_header"
    for link in "${links[@]}"; do
      # process "$i"
      local regex
      page_regex='^.*page=([0-9]+).*$'

      # if this is the 'last' ref...
      if echo "$link" | grep -Fi 'rel="last"'; then
        if [[ $link =~ $page_regex ]]; then
          last_page="${BASH_REMATCH[1]}"
          echo "Last page = $last_page"
        fi
        break
      fi
    done
  fi
}

test