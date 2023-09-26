#!/usr/bin/env bash

if [ -n "${COMMENTER_ECHO+x}" ]; then
  set -x
fi

#############
# Validations
#############
PR_NUMBER=$(echo "$GITHUB_EVENT" | jq -r ".pull_request.number")
if [[ "$PR_NUMBER" == "null" ]]; then
	echo "This isn't a PR."
	exit 0
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
	echo "GITHUB_TOKEN environment variable missing."
	exit 1
fi

if [[ -z $2 ]]; then
    echo "There must be an exit code from a previous step."
    exit 1
fi

if [[ ! "$1" =~ ^(fmt|init|plan|validate)$ ]]; then
  echo -e "Unsupported command \"$1\". Valid commands are \"fmt\", \"init\", \"plan\", \"validate\"."
  exit 1
fi

###########
# Logging #
###########
debug () {
  if [ -n "${COMMENTER_DEBUG+x}" ]; then
    echo -e "\033[33;1mDEBUG:\033[0m $1"
  fi
}

info () {
  echo -e "\033[34;1mINFO:\033[0m $1"
}

error () {
  echo -e "\033[31;1mERROR:\033[0m $1"
}

##################
# Shared Variables
##################
parse_args () {
  # Arg 1 is command
  COMMAND=$1
  # Arg 2 is input file. We strip ANSI colours.
  RAW_INPUT="$COMMENTER_INPUT"
  if test -f "/workspace/${COMMENTER_PLAN_FILE}"; then
    info "Found tfplan; showing."
    pushd workspace > /dev/null || (error "Failed to push workspace dir" && exit 1)
    INIT_OUTPUT="$(terraform init 2>&1)"
    INIT_RESULT=$?
    if [ $INIT_RESULT -ne 0 ]; then
       error "Failed pre-plan init.  Init output: \n$INIT_OUTPUT"
       exit 1
    fi
    RAW_INPUT="$( terraform show "${COMMENTER_PLAN_FILE}" 2>&1 )"
    SHOW_RESULT=$?
    if [ $SHOW_RESULT -ne 0 ]; then
       error "Plan failed to show.  Plan output: \n$RAW_INPUT"
       exit 1
    fi
    popd > /dev/null || (error "Failed to pop workspace dir" && exit 1)
    debug "Plan raw input: $RAW_INPUT"
  else
    info "Found no tfplan.  Proceeding with input argument."
  fi

  # change diff character, a red '-', into a high unicode character \U1f605 (literally 😅)
  # iff not preceded by a literal "/" as in "+/-".
  # this serves as an intermediate representation representing "diff removal line" as distinct from
  # a raw hyphen which could *also* indicate a yaml list entry.
  INPUT=$(echo "$RAW_INPUT" | perl -pe "s/(?<!\/)\e\[31m-\e\[0m/😅/g")

  # now remove all ANSI colors
  INPUT=$(echo "$INPUT" | sed -r 's/\x1b\[[0-9;]*m//g')

  # Arg 3 is the Terraform CLI exit code
  EXIT_CODE=$2

  # Read TF_WORKSPACE environment variable or use "default"
  WORKSPACE=${TF_WORKSPACE:-default}

  # Read EXPAND_SUMMARY_DETAILS environment variable or use "true"
  if [[ ${EXPAND_SUMMARY_DETAILS:-true} == "true" ]]; then
    DETAILS_STATE=" open"
  else
    DETAILS_STATE=""
  fi

  # Read HIGHLIGHT_CHANGES environment variable or use "true"
  COLOURISE=${HIGHLIGHT_CHANGES:-true}

  # Read COMMENTER_POST_PLAN_OUTPUTS environment variable or use "true"
  POST_PLAN_OUTPUTS=${COMMENTER_POST_PLAN_OUTPUTS:-true}

  ACCEPT_HEADER="Accept: application/vnd.github.v3+json"
  AUTH_HEADER="Authorization: token $GITHUB_TOKEN"
  CONTENT_HEADER="Content-Type: application/json"

  PR_COMMENTS_URL=$(echo "$GITHUB_EVENT" | jq -r ".pull_request.comments_url")
  PR_COMMENTS_URL+="?per_page=100"

  PR_COMMENT_URI=$(echo "$GITHUB_EVENT" | jq -r ".repository.issue_comment_url" | sed "s|{/number}||g")
}

###########
# Utility #
###########
make_and_post_payload () {
  # Add plan comment to PR.
  local kind=$1
  local pr_payload=$(echo '{}' | jq --arg body "$2" '.body = $body')
  info "Adding $kind comment to PR."
  debug "PR payload:\n$pr_payload"
  curl -sS -X POST -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -H "$CONTENT_HEADER" -d "$pr_payload" -L "$PR_COMMENTS_URL" > /dev/null
}

# usage:  split_string target_array_name plan_text
split_string () {
  local -n split=$1
  local entire_string=$2
  local remaining_string=$entire_string
  local processed_length=0
  split=()

  debug "Total length to split: ${#remaining_string}"
  # trim to the last newline that fits within length
  while [ ${#remaining_string} -gt 0 ] ; do
    debug "Remaining input: \n${remaining_string}"

    local current_iteration=${remaining_string::65300} # GitHub has a 65535-char comment limit - truncate and iterate
    if [ ${#current_iteration} -ne ${#remaining_string} ] ; then
      debug "String is over 64k length limit.  Splitting at index ${#current_iteration} of ${#remaining_string}."
      current_iteration="${current_iteration%$'\n'*}" # trim to the last newline
      debug "Trimmed split string to index ${#current_iteration}"
    fi
    processed_length=$((processed_length+${#current_iteration})) # evaluate length of outbound comment and store

    debug "Processed string length: ${processed_length}"
    split+=("$current_iteration")

    remaining_string=${entire_string:processed_length}
  done
}

substitute_and_colorize () {
  local current_plan=$1
    current_plan=$(echo "$current_plan" | sed -r 's/^([[:blank:]]*)([😅+~])/\2\1/g' | sed -r 's/^😅/-/')
  if [[ $COLOURISE == 'true' ]]; then
    current_plan=$(echo "$current_plan" | sed -r 's/^~/!/g') # Replace ~ with ! to colourise the diff in GitHub comments
  fi
  echo "$current_plan"
}

get_page_count () {
  local link_header
  local last_page=1

  link_header=$(curl -sSI -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L "$PR_COMMENTS_URL" | grep -i ^link)

  # if I find a matching link header...
  if grep -Fi 'rel="next"' <<< "$link_header"; then
    # we found a next page -> find the last page
    IFS=',' read -ra links <<< "$link_header"
    for link in "${links[@]}"; do
      # process "$i"
      local regex
      page_regex='^.*page=([0-9]+).*$'

      # if this is the 'last' ref...
      if grep -Fi 'rel="last"' <<< "$link" ; then
        if [[ $link =~ $page_regex ]]; then
          last_page="${BASH_REMATCH[1]}"
          break
        fi
      fi
    done
  fi

  eval "$1"="$last_page"
}

delete_existing_comments () {
  # Look for an existing PR comment and delete
  # debug "Existing comments:  $(curl -sS -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L $PR_COMMENTS_URL)"

  local type=$1
  local regex=$2
  local last_page

  local jq='.[] | select(.body|test ("'
  jq+=$regex
  jq+='")) | .id'

  # gross, but... bash.
  get_page_count PAGE_COUNT
  last_page=$PAGE_COUNT
  info "Found $last_page page(s) of comments at $PR_COMMENTS_URL."

  info "Looking for an existing $type PR comment."
  local comment_ids=()
  for page in $(seq $last_page)
  do
    # first, we read *all* of the comment IDs across all pages.  saves us from the problem where we read a page, then
    # delete some, then read the next page, *after* our page boundary has moved due to the delete.
      # CAUTION.  this line assumes the PR_COMMENTS_URL already has at least one query parameter. (note the '&')
    readarray -t -O "${#comment_ids[@]}" comment_ids < <(curl -sS -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L "$PR_COMMENTS_URL&page=$page" | jq "$jq")
  done

  for PR_COMMENT_ID in "${comment_ids[@]}"
  do
    FOUND=true
    info "Found existing $type PR comment: $PR_COMMENT_ID. Deleting."
    PR_COMMENT_URL="$PR_COMMENT_URI/$PR_COMMENT_ID"
    STATUS=$(curl -sS -X DELETE -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -o /dev/null -w "%{http_code}" -L "$PR_COMMENT_URL")
    if [ "$STATUS" != "204"  ]; then
      info "Failed to delete:  status $STATUS (most likely rate limited)"
    fi
  done

  if [ -z $FOUND ]; then
    info "No existing $type PR comment found."
  fi
}

post_diff_comments () {
  local type=$1
  local comment_prefix=$2
  local comment_string=$3

  debug "Total $type length: ${#comment_string}"
  local comment_split
  split_string comment_split "$comment_string"
  local comment_count=${#comment_split[@]}

  info "Writing $comment_count $type comment(s)"

  for i in "${!comment_split[@]}"; do
    local current="${comment_split[$i]}"
    local colorized_comment=$(substitute_and_colorize "$current")
    local comment_count_text=""
    if [ "$comment_count" -ne 1 ]; then
      comment_count_text=" ($((i+1))/$comment_count)"
    fi

    local comment=$(make_details_with_header "$comment_prefix$comment_count_text" "$colorized_comment" "diff")
    make_and_post_payload "$type" "$comment"
  done
}

make_details_with_header() {
  local header="### $1"
  local body=$2
  local format=$3
  local pr_comment="$header
$(make_details "Show Output" "$body" "$format")"
  echo "$pr_comment"
}

make_details() {
  local summary="$1"
  local body=$2
  local format=$3
  local details="<details$DETAILS_STATE><summary>$summary</summary>

\`\`\`$format
$body
\`\`\`
</details>"
  echo "$details"
}

###############
# Handler: plan
###############
execute_plan () {
  delete_existing_comments 'plan' '### Terraform `plan` .* for Workspace: `'$WORKSPACE'`.*'
  delete_existing_comments 'outputs' '### Changes to outputs for Workspace: `'$WORKSPACE'`.*'

  # Exit Code: 0, 2
  # Meaning: 0 = Terraform plan succeeded with no changes. 2 = Terraform plan succeeded with changes.
  # Actions: Strip out the refresh section, ignore everything after the 72 dashes, format, colourise and build PR comment.
  if [[ $EXIT_CODE -eq 0 || $EXIT_CODE -eq 2 ]]; then
    plan_success
  fi

  # Exit Code: 1
  # Meaning: Terraform plan failed.
  # Actions: Build PR comment.
  if [[ $EXIT_CODE -eq 1 ]]; then
    plan_fail
  fi
}

plan_success () {
  post_plan_comments
  if [[ $POST_PLAN_OUTPUTS == 'true' ]]; then
    post_outputs_comments
  fi
}

plan_fail () {
  local comment=$(make_details_with_header "Terraform \`plan\` Failed for Workspace: \`$WORKSPACE\`" "$INPUT")

  # Add plan comment to PR.
  make_and_post_payload "plan failure" "$comment"
}

post_plan_comments () {
  local clean_plan=$(echo "$INPUT" | perl -pe'$_="" unless /(An execution plan has been generated and is shown below.|Terraform used the selected providers to generate the following execution|No changes. Infrastructure is up-to-date.|No changes. Your infrastructure matches the configuration.)/ .. 1') # Strip refresh section
  clean_plan=$(echo "$clean_plan" | sed -r '/Plan: /q') # Ignore everything after plan summary

  post_diff_comments "plan" "Terraform \`plan\` Succeeded for Workspace: \`$WORKSPACE\`" "$clean_plan"
}

post_outputs_comments() {
  local clean_plan=$(echo "$INPUT" | perl -pe'$_="" unless /Changes to Outputs:/ .. 1') # Skip to end of plan summary
  clean_plan=$(echo "$clean_plan" | sed -r '/------------------------------------------------------------------------/q') # Ignore everything after plan summary

  post_diff_comments "outputs" "Changes to outputs for Workspace: \`$WORKSPACE\`" "$clean_plan"
}

##############
# Handler: fmt
##############
execute_fmt () {
  delete_existing_comments 'fmt' '### Terraform `fmt` Failed'

  # Exit Code: 0
  # Meaning: All files formatted correctly.
  # Actions: Exit.
  if [[ $EXIT_CODE -eq 0 ]]; then
    fmt_success
  fi

  # Exit Code: 1, 2
  # Meaning: 1 = Malformed Terraform CLI command. 2 = Terraform parse error.
  # Actions: Build PR comment.
  if [[ $EXIT_CODE -eq 1 || $EXIT_CODE -eq 2 || $EXIT_CODE -eq 3 ]]; then
    fmt_fail
  fi
}

fmt_success () {
  info "Terraform fmt completed with no errors. Continuing."
}

fmt_fail () {
  local pr_comment

  # Exit Code: 1, 2
  # Meaning: 1 = Malformed Terraform CLI command. 2 = Terraform parse error.
  # Actions: Build PR comment.
  if [[ $EXIT_CODE -eq 1 || $EXIT_CODE -eq 2 ]]; then
    pr_comment=$(make_details_with_header "Terraform \`fmt\` Failed" "$INPUT")
  fi

  # Exit Code: 3
  # Meaning: One or more files are incorrectly formatted.
  # Actions: Iterate over all files and build diff-based PR comment.
  if [[ $EXIT_CODE -eq 3 ]]; then
    local all_files_diff=""
    for file in $INPUT; do
      local this_file_diff=$(terraform fmt -no-color -write=false -diff "$file")
      all_files_diff="$all_files_diff
$(make_details "<code>$file</code>" "$this_file_diff" "diff")"
    done

    pr_comment="### Terraform \`fmt\` Failed
$all_files_diff"
  fi

  # Add fmt failure comment to PR.
  make_and_post_payload "fmt failure" "$pr_comment"
}

###############
# Handler: init
###############
execute_init () {
  delete_existing_comments "init" '### Terraform `init` Failed'

  # Exit Code: 0
  # Meaning: Terraform successfully initialized.
  # Actions: Exit.
  if [[ $EXIT_CODE -eq 0 ]]; then
    init_success
  fi

  # Exit Code: 1
  # Meaning: Terraform initialize failed or malformed Terraform CLI command.
  # Actions: Build PR comment.
  if [[ $EXIT_CODE -eq 1 ]]; then
    init_fail
  fi
}

init_success () {
  info "Terraform init completed with no errors. Continuing."
}

init_fail () {
  local pr_comment=$(make_details_with_header "Terraform \`init\` Failed" "$INPUT")

  # Add init failure comment to PR.
  make_and_post_payload "init failure" "$pr_comment"
}

###################
# Handler: validate
###################
execute_validate () {
  delete_existing_comments "validate" '### Terraform `validate` Failed'

  # Exit Code: 0
  # Meaning: Terraform successfully validated.
  # Actions: Exit.
  if [[ $EXIT_CODE -eq 0 ]]; then
    validate_success
  fi

  # Exit Code: 1
  # Meaning: Terraform validate failed or malformed Terraform CLI command.
  # Actions: Build PR comment.
  if [[ $EXIT_CODE -eq 1 ]]; then
    validate_fail
  fi
}

validate_success () {
  info "Terraform validate completed with no errors. Continuing."
}

validate_fail () {
  local pr_comment=$(make_details_with_header "Terraform \`validate\` Failed" "$INPUT")
  make_and_post_payload "validate failure" "$pr_comment"
}

###################
# Procedural body #
###################
parse_args "$@"

if [[ $COMMAND == 'fmt' ]]; then
  execute_fmt
  exit 0
fi

if [[ $COMMAND == 'init' ]]; then
  execute_init
  exit 0
fi

if [[ $COMMAND == 'plan' ]]; then
  execute_plan
  exit 0
fi

if [[ $COMMAND == 'validate' ]]; then
  execute_validate
  exit 0
fi
