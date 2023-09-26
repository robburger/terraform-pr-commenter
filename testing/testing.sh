#!/usr/bin/env bash

if [ -n "${COMMENTER_ECHO+x}" ]; then
  set -x
fi

make_and_post_payload () {
  # Add plan comment to PR.
  PR_PAYLOAD=$(echo '{}' | jq --arg body "$1" '.body = $body')
  info "Adding comment to PR."
  debug "PR payload:\n$PR_PAYLOAD"
  # curl -sS -X POST -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -H "$CONTENT_HEADER" -d "$1" -L "$PR_COMMENTS_URL" > /dev/null
}

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

delete_existing_comments () {
  # Look for an existing plan PR comment and delete
#  echo -e "TEST:  PRS $(curl -sS -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L $PR_COMMENTS_URL)"

  local type=$1
  local regex=$2

  local jq='.[] | select(.body|test ("'
  jq+=$regex
  jq+='")) | .id'
  echo -e "\033[34;1mINFO:\033[0m Looking for an existing $type PR comment."
  for PR_COMMENT_ID in $(curl -sS -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L $PR_COMMENTS_URL | jq "$jq")
  do
    FOUND=true
    echo -e "\033[34;1mINFO:\033[0m Found existing $type PR comment: $PR_COMMENT_ID. Deleting."
    PR_COMMENT_URL="$PR_COMMENT_URI/$PR_COMMENT_ID"
    # curl -sS -X DELETE -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L "$PR_COMMENT_URL" > /dev/null
  done
  if [ -z $FOUND ]; then
    echo -e "\033[34;1mINFO:\033[0m No existing $type PR comment found."
  fi
}

post_comments () {
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
    local comment="$comment_prefix$comment_count_text
<details$DETAILS_STATE><summary>Show Output</summary>

\`\`\`diff
$colorized_comment
\`\`\`
</details>"
    make_and_post_payload "$comment"
  done
}

post_plan_comments () {
  local clean_plan=$(echo "$INPUT" | perl -pe'$_="" unless /(An execution plan has been generated and is shown below.|Terraform used the selected providers to generate the following execution|No changes. Infrastructure is up-to-date.|No changes. Your infrastructure matches the configuration.)/ .. 1') # Strip refresh section
  clean_plan=$(echo "$clean_plan" | sed -r '/Plan: /q') # Ignore everything after plan summary

  post_comments "plan" "### Terraform \`plan\` Succeeded for Workspace: \`$WORKSPACE\`" "$clean_plan"
}

post_outputs_comments() {
  local clean_plan=$(echo "$INPUT" | perl -pe'$_="" unless /Changes to Outputs:/ .. 1') # Skip to end of plan summary
  clean_plan=$(echo "$clean_plan" | sed -r '/------------------------------------------------------------------------/q') # Ignore everything after plan summary

  post_comments "outputs" "### Changes to outputs for Workspace: \`$WORKSPACE\`" "$clean_plan"
}

plan_success () {
  post_plan_comments
  if [[ $POST_PLAN_OUTPUTS == 'true' ]]; then
    post_outputs_comments
  fi
}

plan_fail () {
  local comment="### Terraform \`plan\` Failed for Workspace: \`$WORKSPACE\`
<details$DETAILS_STATE><summary>Show Output</summary>

\`\`\`
$INPUT
\`\`\`
</details>"

  # Add plan comment to PR.
  make_and_post_payload "$(echo '{}' | jq --arg body "$comment" '.body = $body')"
}

plan_fail () {
  local comment="### Terraform \`plan\` Failed for Workspace: \`$WORKSPACE\`
<details$DETAILS_STATE><summary>Show Output</summary>

\`\`\`
$INPUT
\`\`\`
</details>"

  # Add plan comment to PR.
  make_and_post_payload "$(echo '{}' | jq --arg body "$comment" '.body = $body')"
}

###############
# Handler: plan
###############
execute_plan () {
  delete_existing_comments 'plan' '### Terraform `plan` .* for Workspace: `'$WORKSPACE'`'

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



read -r -d '' RAW_INPUT <<'EOI'
random_pet.eks: Refreshing state... [id=mighty-crab]
random_string.datadog_agent_token[0]: Refreshing state... [id=sKASHxANYnwscJqDfQRRRUnYWFIVUVkz]
datadog_monitor.datadog_log_volume_daily_quota: Refreshing state... [id=46013123]
datadog_monitor.kubernetes_node_state: Refreshing state... [id=42536272]
datadog_logs_custom_pipeline.cloudwatch_forwarded_logs: Refreshing state... [id=j-fz8ijrTcmfdKK0gLJSmw]
datadog_monitor.kubernetes_cpu: Refreshing state... [id=28636430]
datadog_logs_archive.dd-logs-archive: Refreshing state... [id=JzsLarnNRri4scQkVH6iYw]
datadog_monitor.kubernetes_pod_pending: Refreshing state... [id=42536271]
datadog_monitor.kubernetes_pod_availability: Refreshing state... [id=42536269]
datadog_monitor.kubernetes_pod_imagepullbackoff: Refreshing state... [id=43979968]
datadog_monitor.kubernetes_pod_status: Refreshing state... [id=42536274]
datadog_dashboard_list.sre_eks_dashboard_list: Refreshing state... [id=231117]
datadog_monitor.kubernetes_disk: Refreshing state... [id=42536273]
datadog_logs_custom_pipeline.botkube_glog_logs: Refreshing state... [id=ymtWat48SdSijdzxbuCkxQ]
datadog_logs_custom_pipeline.linkerd_proxy_logs: Refreshing state... [id=SgxdKPUITXySy-QF4iU5oQ]
datadog_logs_custom_pipeline.traefig_glog_logs: Refreshing state... [id=bY5FOXJWTFuvegamSNc8Sg]
datadog_logs_custom_pipeline.linkerd_tap_logs: Refreshing state... [id=qaAXk6bySOK6ohXZERfjag]
datadog_monitor.kubernetes_pod_capacity: Refreshing state... [id=50708240]
datadog_monitor.datadog_log_volume: Refreshing state... [id=45247461]
datadog_logs_custom_pipeline.istio_envoy_logs: Refreshing state... [id=t_3qTz6OQGuDgbyQvh5psw]
datadog_monitor.kubernetes_mem: Refreshing state... [id=42536270]
datadog_logs_custom_pipeline.datadog_trace_startup_logs: Refreshing state... [id=MowGqIBKQT-jQkR4XEVM8g]
module.eks_vpc.aws_vpc.this[0]: Refreshing state... [id=vpc-04ff83d39ddba4b4d]
module.eks_vpc.aws_eip.nat[0]: Refreshing state... [id=eipalloc-0c170bdb85bae72b3]
module.eks_vpc.aws_eip.nat[1]: Refreshing state... [id=eipalloc-0eeba723bb4d25ea3]
module.eks_vpc.aws_eip.nat[2]: Refreshing state... [id=eipalloc-05845bbfdf5ee8090]
aws_s3_bucket.dd-logs-archive-bucket: Refreshing state... [id=prod-midwest-dd-log-archive]
aws_iam_role.fargate_pod_executor: Refreshing state... [id=eks-fargate-pod-executor]
aws_acm_certificate.terminus_tools[0]: Refreshing state... [id=arn:aws:acm:us-east-1:***:certificate/1d076d27-d592-4e4f-91d5-c76ac575dc2b]
aws_acm_certificate.terminus_tools_no_wildcard[0]: Refreshing state... [id=arn:aws:acm:us-east-1:***:certificate/13ae5547-167f-4ffd-ad5e-60c67d30348e]
module.eks.aws_cloudwatch_log_group.this[0]: Refreshing state... [id=/aws/eks/prod-midwest-mighty-crab/cluster]
aws_ssm_document.node_drainer[0]: Refreshing state... [id=prod-midwest-mighty-crab-node-drainer]
datadog_dashboard_json.sre_kubernetes: Refreshing state... [id=4ay-98x-tnj]
aws_iam_role.eks_readonly[0]: Refreshing state... [id=eks-readonly]
module.eks.aws_iam_role.cluster[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014132921928700000001]
aws_iam_policy.lifecycle_hook_access[0]: Refreshing state... [id=arn:aws:iam::***:policy/eks/prod-midwest-mighty-crab-lifecycle-hook-access]
aws_iam_policy.eks_readonly_policy[0]: Refreshing state... [id=arn:aws:iam::***:policy/eks/eks-readonly]
aws_iam_policy.eks_admin_policy[0]: Refreshing state... [id=arn:aws:iam::***:policy/eks/eks-admin]
aws_iam_role.node_drainer[0]: Refreshing state... [id=prod-midwest-mighty-crab-node-drainer]
aws_iam_policy.cni_put_metrics_role_policy: Refreshing state... [id=arn:aws:iam::***:policy/eks/CNIMetricsHelperPolicy]
aws_iam_role_policy_attachment.AmazonEKSFargatePodExecutionRolePolicy: Refreshing state... [id=eks-fargate-pod-executor-20201014134739157000000001]
aws_iam_role.eks_admin[0]: Refreshing state... [id=eks-admin]
aws_security_group.eks_db_subnet_access: Refreshing state... [id=sg-061be5c1a9526cb1b]
module.eks.aws_security_group.cluster[0]: Refreshing state... [id=sg-091ec20585b4dadc2]
module.eks_vpc.aws_vpc_endpoint.s3[0]: Refreshing state... [id=vpce-0baaef11d3995b842]
module.eks_vpc.aws_vpc_endpoint.dynamodb[0]: Refreshing state... [id=vpce-028c97b5db9d679ed]
module.eks_vpc.aws_internet_gateway.this[0]: Refreshing state... [id=igw-02cf7d8f6858f8a22]
module.eks_vpc.aws_subnet.public[0]: Refreshing state... [id=subnet-0f803e12464d4d018]
module.eks_vpc.aws_subnet.public[1]: Refreshing state... [id=subnet-0e34de2801aa56246]
module.eks_vpc.aws_subnet.public[2]: Refreshing state... [id=subnet-08b2f9179750b44db]
module.eks_vpc.aws_route_table.private[0]: Refreshing state... [id=rtb-0be98fc226f199aeb]
module.eks_vpc.aws_route_table.private[1]: Refreshing state... [id=rtb-0799f7610a5705a7c]
module.eks_vpc.aws_route_table.private[2]: Refreshing state... [id=rtb-0783fe9149db77c26]
module.eks.aws_iam_role_policy_attachment.cluster_AmazonEKSServicePolicy[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014132921928700000001-20201014132922591200000002]
module.eks.aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014132921928700000001-20201014132922618600000003]
module.eks_vpc.aws_route_table.public[0]: Refreshing state... [id=rtb-08f038602531af595]
module.eks_vpc.aws_subnet.private[1]: Refreshing state... [id=subnet-04c14856ef9593c5a]
module.eks_vpc.aws_subnet.private[0]: Refreshing state... [id=subnet-0dd47e406fc214453]
module.eks_vpc.aws_subnet.private[2]: Refreshing state... [id=subnet-0c945c0315bb9c9ad]
aws_route53_record.terminus_tools["*.prod-midwest.terminus.tools"]: Refreshing state... [id=Z0157238VB243EMUUOC3__3a240892ebd676d1ec5580329ead1da9.prod-midwest.terminus.tools._CNAME]
aws_route53_record.terminus_tools["*.terminus.tools"]: Refreshing state... [id=Z0157238VB243EMUUOC3__32b4e034dadfe7146b3853d966e4c42c.terminus.tools._CNAME]
aws_route53_record.terminus_tools_no_wildcard["terminus.tools"]: Refreshing state... [id=Z0157238VB243EMUUOC3__32b4e034dadfe7146b3853d966e4c42c.terminus.tools._CNAME]
aws_iam_role_policy_attachment.eks_readonly_policy_attach[0]: Refreshing state... [id=eks-readonly-20211027161122470900000001]
module.eks.aws_security_group_rule.cluster_egress_internet[0]: Refreshing state... [id=sgrule-3112590249]
aws_iam_role_policy.node_drainer[0]: Refreshing state... [id=prod-midwest-mighty-crab-node-drainer:eks-node-drainer]
aws_iam_role_policy_attachment.eks_admin_policy_attach[0]: Refreshing state... [id=eks-admin-20210727185149890500000001]
module.eks_vpc.aws_vpc_endpoint_route_table_association.private_s3[0]: Refreshing state... [id=a-vpce-0baaef11d3995b8423337404169]
module.eks_vpc.aws_vpc_endpoint_route_table_association.private_s3[1]: Refreshing state... [id=a-vpce-0baaef11d3995b84280810125]
module.eks_vpc.aws_vpc_endpoint_route_table_association.private_s3[2]: Refreshing state... [id=a-vpce-0baaef11d3995b8421404072536]
module.eks_vpc.aws_nat_gateway.this[0]: Refreshing state... [id=nat-0bf69456fd35e1cda]
module.eks_vpc.aws_nat_gateway.this[1]: Refreshing state... [id=nat-0aa6b81307e69e55f]
module.eks_vpc.aws_nat_gateway.this[2]: Refreshing state... [id=nat-04e04fe307e062163]
module.eks_vpc.aws_vpc_endpoint_route_table_association.private_dynamodb[0]: Refreshing state... [id=a-vpce-028c97b5db9d679ed3337404169]
module.eks_vpc.aws_vpc_endpoint_route_table_association.private_dynamodb[2]: Refreshing state... [id=a-vpce-028c97b5db9d679ed1404072536]
module.eks_vpc.aws_vpc_endpoint_route_table_association.private_dynamodb[1]: Refreshing state... [id=a-vpce-028c97b5db9d679ed80810125]
module.eks_vpc.aws_vpc_endpoint_route_table_association.public_dynamodb[0]: Refreshing state... [id=a-vpce-028c97b5db9d679ed2523514364]
module.eks_vpc.aws_route_table_association.public[0]: Refreshing state... [id=rtbassoc-06305c1f056349b6a]
module.eks_vpc.aws_route_table_association.public[1]: Refreshing state... [id=rtbassoc-028d0ddfc13d6dade]
module.eks_vpc.aws_route_table_association.public[2]: Refreshing state... [id=rtbassoc-05183d2d439aa4a2b]
module.eks_vpc.aws_vpc_endpoint_route_table_association.public_s3[0]: Refreshing state... [id=a-vpce-0baaef11d3995b8422523514364]
module.eks_vpc.aws_route.public_internet_gateway[0]: Refreshing state... [id=r-rtb-08f038602531af5951080289494]
module.eks_vpc.aws_route_table_association.private[0]: Refreshing state... [id=rtbassoc-00397c3925e11ff0e]
module.eks_vpc.aws_route_table_association.private[2]: Refreshing state... [id=rtbassoc-03ada92fc27d5d778]
module.eks_vpc.aws_route_table_association.private[1]: Refreshing state... [id=rtbassoc-097a41e0d52a10a99]
aws_acm_certificate_validation.terminus_tools[0]: Refreshing state... [id=2021-11-17 21:02:17.798 +0000 UTC]
aws_acm_certificate_validation.terminus_tools_no_wildcard[0]: Refreshing state... [id=2021-11-17 21:02:15.747 +0000 UTC]
module.eks_vpc.aws_route.private_nat_gateway[0]: Refreshing state... [id=r-rtb-0be98fc226f199aeb1080289494]
module.eks_vpc.aws_route.private_nat_gateway[1]: Refreshing state... [id=r-rtb-0799f7610a5705a7c1080289494]
module.eks_vpc.aws_route.private_nat_gateway[2]: Refreshing state... [id=r-rtb-0783fe9149db77c261080289494]
module.eks.aws_eks_cluster.this: Refreshing state... [id=prod-midwest-mighty-crab]
module.eks.aws_iam_role.workers[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014134016318400000005]
module.eks.aws_security_group.workers[0]: Refreshing state... [id=sg-0a85a7dc1373ecf6b]
module.eks.aws_iam_policy.worker_autoscaling[0]: Refreshing state... [id=arn:aws:iam::***:policy/eks/eks-worker-autoscaling-prod-midwest-mighty-crab20201014134016343400000007]
aws_iam_openid_connect_provider.eks_cluster: Refreshing state... [id=arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377]
module.eks.aws_security_group_rule.workers_egress_internet[0]: Refreshing state... [id=sgrule-68981973]
module.eks.aws_security_group_rule.workers_ingress_cluster_https[0]: Refreshing state... [id=sgrule-413899233]
module.eks.aws_security_group_rule.cluster_https_worker_ingress[0]: Refreshing state... [id=sgrule-2171936441]
module.eks.aws_security_group_rule.workers_ingress_cluster[0]: Refreshing state... [id=sgrule-3862769421]
module.eks.aws_security_group_rule.workers_ingress_self[0]: Refreshing state... [id=sgrule-174023373]
module.eks.aws_iam_role_policy_attachment.workers_autoscaling[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014134016318400000005-2020101413401727460000000c]
module.eks.aws_iam_role_policy_attachment.workers_AmazonEC2ContainerRegistryReadOnly[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014134016318400000005-2020101413401727060000000b]
module.eks.aws_iam_role_policy_attachment.workers_AmazonEKSWorkerNodePolicy[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014134016318400000005-20201014134017246100000009]
module.eks.aws_iam_role_policy_attachment.workers_AmazonEKS_CNI_Policy[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014134016318400000005-2020101413401734310000000e]
module.eks.aws_iam_instance_profile.workers[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014134017057300000008]
module.eks.aws_iam_role_policy_attachment.workers_additional_policies[0]: Refreshing state... [id=prod-midwest-mighty-crab20201014134016318400000005-20211202190217976000000001]
module.eks.aws_iam_role_policy_attachment.workers_additional_policies[2]: Refreshing state... [id=prod-midwest-mighty-crab20201014134016318400000005-20211202190217978100000002]
module.eks.aws_iam_role_policy_attachment.workers_additional_policies[1]: Refreshing state... [id=prod-midwest-mighty-crab20201014134016318400000005-20211202190218001700000003]
module.eks_namespace_cert_manager.kubernetes_namespace.this[0]: Refreshing state... [id=cert-manager]
module.eks_namespace_traefik.kubernetes_namespace.this[0]: Refreshing state... [id=traefik]
module.eks_namespace_terminus_system.kubernetes_namespace.this[0]: Refreshing state... [id=terminus-system]
module.eks_namespace_linkerd.kubernetes_namespace.this[0]: Refreshing state... [id=linkerd]
kubernetes_cluster_role.node_drainer[0]: Refreshing state... [id=system:node-drainer]
kubernetes_cluster_role.crd_read_access[0]: Refreshing state... [id=view-crd]
kubernetes_cluster_role.global_read_access[0]: Refreshing state... [id=view-everything]
kubernetes_cluster_role_binding.read_access[0]: Refreshing state... [id=view]
kubernetes_cluster_role.traefik_crd_view: Refreshing state... [id=traefik-view]
kubernetes_cluster_role.traefik_crd_edit: Refreshing state... [id=traefik-edit]
kubernetes_cluster_role.fargate_datadog_agent: Refreshing state... [id=fargate-datadog-agent]
kubernetes_cluster_role.linkerd_crd_edit: Refreshing state... [id=linkerd-edit]
kubernetes_cluster_role.linkerd_crd_view: Refreshing state... [id=linkerd-view]
module.eks.aws_launch_configuration.workers[0]: Refreshing state... [id=prod-midwest-mighty-crab-apps20211116020406559000000001]
module.eks_namespace_linkerd.kubernetes_role.full_access[0]: Refreshing state... [id=linkerd/full-access]
module.eks_namespace_cert_manager.kubernetes_role.full_access[0]: Refreshing state... [id=cert-manager/full-access]
module.eks_namespace_terminus_system.kubernetes_role.read_only[0]: Refreshing state... [id=terminus-system/read-only]
module.eks_namespace_linkerd.kubernetes_role.read_only[0]: Refreshing state... [id=linkerd/read-only]
module.eks_namespace_cert_manager.kubernetes_role.read_only[0]: Refreshing state... [id=cert-manager/read-only]
module.eks_namespace_terminus_system.kubernetes_role.full_access[0]: Refreshing state... [id=terminus-system/full-access]
module.eks_namespace_traefik.kubernetes_role.read_only[0]: Refreshing state... [id=traefik/read-only]
module.eks_namespace_traefik.kubernetes_role.full_access[0]: Refreshing state... [id=traefik/full-access]
kubernetes_cluster_role_binding.node_drainer[0]: Refreshing state... [id=node-drainer]
kubernetes_ingress.traefik_alb[0]: Refreshing state... [id=traefik/traefik-alb]
module.eks.random_pet.workers[0]: Refreshing state... [id=divine-sloth]
module.cert_manager.helm_release.cert_manager[0]: Refreshing state... [id=cert-manager]
helm_release.datadog[0]: Refreshing state... [id=datadog]
kubernetes_ingress.traefik_internal_alb[0]: Refreshing state... [id=traefik/traefik-internal-alb]
module.eks_namespace_cert_manager.kubernetes_role_binding.full_access[0]: Refreshing state... [id=cert-manager/full-access]
module.eks_namespace_linkerd.kubernetes_role_binding.full_access[0]: Refreshing state... [id=linkerd/full-access]
module.eks_namespace_terminus_system.kubernetes_role_binding.full_access[0]: Refreshing state... [id=terminus-system/full-access]
module.eks_namespace_terminus_system.kubernetes_role_binding.read_only[0]: Refreshing state... [id=terminus-system/read-only]
module.eks_namespace_cert_manager.kubernetes_role_binding.read_only[0]: Refreshing state... [id=cert-manager/read-only]
module.eks_namespace_linkerd.kubernetes_role_binding.read_only[0]: Refreshing state... [id=linkerd/read-only]
module.eks_namespace_traefik.kubernetes_role_binding.full_access[0]: Refreshing state... [id=traefik/full-access]
kubernetes_manifest.cni-metrics-helper-cluster-role-binding: Refreshing state...
module.eks_namespace_traefik.kubernetes_role_binding.read_only[0]: Refreshing state... [id=traefik/read-only]
aws_iam_role.external_dns[0]: Refreshing state... [id=external-dns]
aws_iam_role.ingress_controller[0]: Refreshing state... [id=aws-alb-ingress-controller]
module.eks.aws_autoscaling_group.workers[0]: Refreshing state... [id=prod-midwest-mighty-crab-apps-divine-sloth20211116020407529900000002]
kubernetes_manifest.cni-metrics-helper-cluster-role: Refreshing state...
module.external_dns_terminustools.aws_iam_role.external_dns[0]: Refreshing state... [id=terminustools-external-dns]
module.external_dns_terminusplatform.aws_iam_role.external_dns[0]: Refreshing state... [id=terminusplatform-external-dns]
kubernetes_manifest.cni-metrics-helper-service-account: Refreshing state...
module.eks.kubernetes_config_map.aws_auth[0]: Refreshing state... [id=kube-system/aws-auth]
aws_cloudwatch_event_rule.ec2_state_transition[0]: Refreshing state... [id=prod-midwest-mighty-crab-capture-ec2-terminating]
kubernetes_manifest.cni-metrics-helper-deployment: Refreshing state...
aws_eks_addon.kube_proxy[0]: Refreshing state... [id=prod-midwest-mighty-crab:kube-proxy]
aws_eks_addon.core_dns[0]: Refreshing state... [id=prod-midwest-mighty-crab:coredns]
aws_eks_addon.vpc_cni[0]: Refreshing state... [id=prod-midwest-mighty-crab:vpc-cni]
module.eks_namespace_linkerd_viz.kubernetes_namespace.this[0]: Refreshing state... [id=linkerd-dashboard]
module.eks_namespace_linkerd_cni.kubernetes_namespace.this[0]: Refreshing state... [id=linkerd-cni]
aws_cloudwatch_event_target.ec2_state_transition[0]: Refreshing state... [id=prod-midwest-mighty-crab-capture-ec2-terminating-terraform-20201014134109541700000011]
helm_release.external_dns[0]: Refreshing state... [id=external-dns]
aws_iam_role_policy.external_dns[0]: Refreshing state... [id=external-dns:external-dns-r53-access]
module.eks_namespace_linkerd_viz.kubernetes_role.read_only[0]: Refreshing state... [id=linkerd-dashboard/read-only]
module.eks_namespace_linkerd_viz.kubernetes_role.full_access[0]: Refreshing state... [id=linkerd-dashboard/full-access]
module.eks_namespace_linkerd_cni.kubernetes_role.read_only[0]: Refreshing state... [id=linkerd-cni/read-only]
module.eks_namespace_linkerd_cni.kubernetes_role.full_access[0]: Refreshing state... [id=linkerd-cni/full-access]
helm_release.ingress_controller[0]: Refreshing state... [id=aws-alb-ingress-controller]
aws_iam_role_policy.ingress_controller[0]: Refreshing state... [id=aws-alb-ingress-controller:eks-ingress-controller-alb-mgmt]
module.eks_namespace_linkerd_viz.kubernetes_role_binding.read_only[0]: Refreshing state... [id=linkerd-dashboard/read-only]
module.eks_namespace_linkerd_cni.kubernetes_role_binding.read_only[0]: Refreshing state... [id=linkerd-cni/read-only]
module.eks_namespace_linkerd_viz.kubernetes_role_binding.full_access[0]: Refreshing state... [id=linkerd-dashboard/full-access]
module.eks_namespace_linkerd_cni.kubernetes_role_binding.full_access[0]: Refreshing state... [id=linkerd-cni/full-access]
module.external_dns_terminustools.aws_iam_role_policy.external_dns[0]: Refreshing state... [id=terminustools-external-dns:external-dns-r53-access]
module.external_dns_terminustools.helm_release.external_dns[0]: Refreshing state... [id=terminustools-external-dns]
module.external_dns_terminusplatform.helm_release.external_dns[0]: Refreshing state... [id=terminusplatform-external-dns]
module.external_dns_terminusplatform.aws_iam_role_policy.external_dns[0]: Refreshing state... [id=terminusplatform-external-dns:external-dns-r53-access]
module.linkerd.null_resource.module_depends_on["cert_manager_status"]: Refreshing state... [id=3587086136560643959]
module.linkerd.tls_private_key.linkerd_trust_anchor[0]: Refreshing state... [id=1a4525564825f95e44b33bc6e28adb745387bf33]
module.linkerd.tls_self_signed_cert.linkerd_trust_anchor[0]: Refreshing state... [id=316199143599888869802368478346395450892]
module.linkerd.kubernetes_secret.linkerd_trust_anchor[0]: Refreshing state... [id=linkerd/linkerd-trust-anchor]
module.linkerd.helm_release.linkerd_ca[0]: Refreshing state... [id=linkerd-ca]
module.linkerd.helm_release.linkerd[0]: Refreshing state... [id=linkerd]
module.linkerd.helm_release.linkerd_viz[0]: Refreshing state... [id=linkerd-viz]
module.linkerd.helm_release.linkerd_cni[0]: Refreshing state... [id=linkerd-cni]
module.traefik.null_resource.module_depends_on["linkerd_ca_status"]: Refreshing state... [id=5396547641986912147]
module.traefik.null_resource.module_depends_on["linkerd_status"]: Refreshing state... [id=9019411834470927621]
module.traefik.helm_release.traefik[0]: Refreshing state... [id=traefik]
module.linkerd.helm_release.linkerd_viz_ingress[0]: Refreshing state... [id=linkerd-viz-ingress]
module.traefik.helm_release.traefik_dashboard_ingress[0]: Refreshing state... [id=traefik-dashboard-ingress]
module.traefik.helm_release.traefik_forward_auth_traefik_dashboard[0]: Refreshing state... [id=okta-traefik-dashboard]
module.traefik.helm_release.traefik_forward_auth_linkerd_viz[0]: Refreshing state... [id=traefik-forward-auth-linkerd-viz]
module.traefik.helm_release.middleware[0]: Refreshing state... [id=middleware]
module.eks_namespace_botkube.kubernetes_namespace.this[0]: Refreshing state... [id=botkube]
module.eks_namespace_botkube.kubernetes_role.read_only[0]: Refreshing state... [id=botkube/read-only]
module.eks_namespace_botkube.kubernetes_role.full_access[0]: Refreshing state... [id=botkube/full-access]
module.eks_namespace_botkube.kubernetes_role_binding.read_only[0]: Refreshing state... [id=botkube/read-only]
module.eks_namespace_botkube.kubernetes_role_binding.full_access[0]: Refreshing state... [id=botkube/full-access]
module.botkube[0].helm_release.botkube[0]: Refreshing state... [id=botkube]

An execution plan has been generated and is shown below.
Resource actions are indicated with the following symbols:
  ~ update in-place
+/- create replacement and then destroy
 <= read (data resources)

Terraform will perform the following actions:

  # aws_iam_role.external_dns[0] will be updated in-place
  ~ resource "aws_iam_role" "external_dns" {
      ~ assume_role_policy    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:terminus-system:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
        id                    = "external-dns"
        name                  = "external-dns"
        tags                  = {
            "DeploymentName" = "EKS"
            "Environment"    = "Production"
            "ManagedBy"      = "https://github.com/GetTerminus/eks-infra"
            "ServiceName"    = "EKS"
            "Shared"         = "True"
            "Team"           = "SRE"
        }
        # (9 unchanged attributes hidden)

        # (1 unchanged block hidden)
    }

  # aws_iam_role.ingress_controller[0] will be updated in-place
  ~ resource "aws_iam_role" "ingress_controller" {
      ~ assume_role_policy    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:terminus-system:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
        id                    = "aws-alb-ingress-controller"
        name                  = "aws-alb-ingress-controller"
        tags                  = {
            "DeploymentName" = "EKS"
            "Environment"    = "Production"
            "ManagedBy"      = "https://github.com/GetTerminus/eks-infra"
            "ServiceName"    = "EKS"
            "Shared"         = "True"
            "Team"           = "SRE"
        }
        # (9 unchanged attributes hidden)

        # (1 unchanged block hidden)
    }

  # module.botkube[0].data.template_file.botkube_values will be read during apply
  # (config refers to values not yet known)
 <= data "template_file" "botkube_values"  {
      ~ id       = "8652a3dd0df5cad1b3ef3685dc07e5cedc771920f0a51d3f7bacc6925e7945a2" -> (known after apply)
      ~ rendered = <<-EOT
            # Values for BotKube.
            # This is a YAML-formatted file.

            image:
              repository: infracloudio/botkube
              tag: v0.12.3

            config:
              ## Resources you want to watch
              resources:
                - name: v1/pods             # Name of the resource. Resource name must be in group/version/resource (G/V/R) format
                  # resource name should be plural (e.g apps/v1/deployments, v1/pods)
                  namespaces:               # List of namespaces, "all" will watch all the namespaces
                    include:
                      - all
                    ignore:                 # List of namespaces to be ignored (omitempty), used only with include: all, can contain a wildcard (*)
                      -                     # example : include [all], ignore [x,y,secret-ns-*]
                  events:                   # List of lifecycle events you want to receive, e.g create, update, delete, error OR all
                    - error
                - name: v1/services
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: apps/v1/deployments
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                  updateSetting:
                    includeDiff: true
                    fields:
                      - spec.template.spec.containers[*].image
                      - status.availableReplicas
                - name: apps/v1/statefulsets
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                  updateSetting:
                    includeDiff: true
                    fields:
                      - spec.template.spec.containers[*].image
                      - status.readyReplicas
                - name: networking.k8s.io/v1beta1/ingresses
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: v1/nodes
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: v1/namespaces
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: v1/persistentvolumes
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: v1/persistentvolumeclaims
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: v1/configmaps
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: apps/v1/daemonsets
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                  updateSetting:
                    includeDiff: true
                    fields:
                      - spec.template.spec.containers[*].image
                      - status.numberReady
                - name: batch/v1/jobs
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                  updateSetting:
                    includeDiff: true
                    fields:
                      - spec.template.spec.containers[*].image
                      - status.conditions[*].type
                - name: rbac.authorization.k8s.io/v1/roles
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: rbac.authorization.k8s.io/v1/rolebindings
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: rbac.authorization.k8s.io/v1/clusterrolebindings
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                - name: rbac.authorization.k8s.io/v1/clusterroles
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - create
                    - delete
                    - error
                # Custom resource
                - name: traefik.containo.us/v1alpha1/IngressRoute
                  namespaces:
                    include:
                      - all
                    ignore:
                      -
                  events:
                    - error
                  updateSetting:
                    includeDiff: true
                    fields:
                      - status.phase

              # Setting to support multiple clusters
              settings:
                # Cluster name to differentiate incoming messages
                clustername: prod-midwest
                # Kubectl executor configs
                kubectl:
                  # Set true to enable kubectl commands execution
                  enabled: false


            # Communication settings
            communications:

              # Using existing Communication secret
              existingSecretName: ""

              # Settings for Slack
              slack:
                enabled: true
                channel: k8s-prod-midwest                   # Slack channel name without '#' prefix where you have added BotKube and want to receive notifications in
                token: xoxb-6726794291-2448694983552-hIZnqC8votMn0jD4UXHkaKbi
                notiftype: short                           # Change notification type short/long you want to receive. notiftype is optional and Default notification type is short (if not specified)


            serviceAccount:

              # annotations for the service account
              annotations:
                 eks.amazonaws.com/role-arn: arn:aws:iam::***:role/eks/eks-readonly
        EOT -> (known after apply)
        # (2 unchanged attributes hidden)
    }

  # module.botkube[0].helm_release.botkube[0] will be updated in-place
  ~ resource "helm_release" "botkube" {
        id                         = "botkube"
        name                       = "botkube"
      ~ values                     = [
          - <<-EOT
                # Values for BotKube.
                # This is a YAML-formatted file.

                image:
                  repository: infracloudio/botkube
                  tag: v0.12.3

                config:
                  ## Resources you want to watch
                  resources:
                    - name: v1/pods             # Name of the resource. Resource name must be in group/version/resource (G/V/R) format
                      # resource name should be plural (e.g apps/v1/deployments, v1/pods)
                      namespaces:               # List of namespaces, "all" will watch all the namespaces
                        include:
                          - all
                        ignore:                 # List of namespaces to be ignored (omitempty), used only with include: all, can contain a wildcard (*)
                          -                     # example : include [all], ignore [x,y,secret-ns-*]
                      events:                   # List of lifecycle events you want to receive, e.g create, update, delete, error OR all
                        - error
                    - name: v1/services
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: apps/v1/deployments
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                      updateSetting:
                        includeDiff: true
                        fields:
                          - spec.template.spec.containers[*].image
                          - status.availableReplicas
                    - name: apps/v1/statefulsets
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                      updateSetting:
                        includeDiff: true
                        fields:
                          - spec.template.spec.containers[*].image
                          - status.readyReplicas
                    - name: networking.k8s.io/v1beta1/ingresses
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: v1/nodes
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: v1/namespaces
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: v1/persistentvolumes
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: v1/persistentvolumeclaims
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: v1/configmaps
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: apps/v1/daemonsets
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                      updateSetting:
                        includeDiff: true
                        fields:
                          - spec.template.spec.containers[*].image
                          - status.numberReady
                    - name: batch/v1/jobs
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                      updateSetting:
                        includeDiff: true
                        fields:
                          - spec.template.spec.containers[*].image
                          - status.conditions[*].type
                    - name: rbac.authorization.k8s.io/v1/roles
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: rbac.authorization.k8s.io/v1/rolebindings
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: rbac.authorization.k8s.io/v1/clusterrolebindings
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                    - name: rbac.authorization.k8s.io/v1/clusterroles
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - create
                        - delete
                        - error
                    # Custom resource
                    - name: traefik.containo.us/v1alpha1/IngressRoute
                      namespaces:
                        include:
                          - all
                        ignore:
                          -
                      events:
                        - error
                      updateSetting:
                        includeDiff: true
                        fields:
                          - status.phase

                  # Setting to support multiple clusters
                  settings:
                    # Cluster name to differentiate incoming messages
                    clustername: prod-midwest
                    # Kubectl executor configs
                    kubectl:
                      # Set true to enable kubectl commands execution
                      enabled: false


                # Communication settings
                communications:

                  # Using existing Communication secret
                  existingSecretName: ""

                  # Settings for Slack
                  slack:
                    enabled: true
                    channel: k8s-prod-midwest                   # Slack channel name without '#' prefix where you have added BotKube and want to receive notifications in
                    token: xoxb-6726794291-2448694983552-hIZnqC8votMn0jD4UXHkaKbi
                    notiftype: short                           # Change notification type short/long you want to receive. notiftype is optional and Default notification type is short (if not specified)


                serviceAccount:

                  # annotations for the service account
                  annotations:
                     eks.amazonaws.com/role-arn: arn:aws:iam::***:role/eks/eks-readonly
            EOT,
        ] -> (known after apply)
        # (25 unchanged attributes hidden)
    }

  # module.eks.data.aws_iam_policy_document.worker_autoscaling will be read during apply
  # (config refers to values not yet known)
 <= data "aws_iam_policy_document" "worker_autoscaling"  {
      ~ id      = "3978599367" -> (known after apply)
      ~ json    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action   = [
                          - "ec2:DescribeLaunchTemplateVersions",
                          - "autoscaling:DescribeTags",
                          - "autoscaling:DescribeLaunchConfigurations",
                          - "autoscaling:DescribeAutoScalingInstances",
                          - "autoscaling:DescribeAutoScalingGroups",
                        ]
                      - Effect   = "Allow"
                      - Resource = "*"
                      - Sid      = "eksWorkerAutoscalingAll"
                    },
                  - {
                      - Action    = [
                          - "autoscaling:UpdateAutoScalingGroup",
                          - "autoscaling:TerminateInstanceInAutoScalingGroup",
                          - "autoscaling:SetDesiredCapacity",
                        ]
                      - Condition = {
                          - StringEquals = {
                              - autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled              = "true"
                              - autoscaling:ResourceTag/kubernetes.io/cluster/prod-midwest-mighty-crab = "owned"
                            }
                        }
                      - Effect    = "Allow"
                      - Resource  = "*"
                      - Sid       = "eksWorkerAutoscalingOwn"
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
      - version = "2012-10-17" -> null

      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
            # (4 unchanged attributes hidden)
        }
      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
            # (4 unchanged attributes hidden)

            # (2 unchanged blocks hidden)
        }
    }

  # module.eks.data.template_file.config_map_aws_auth will be read during apply
  # (config refers to values not yet known)
 <= data "template_file" "config_map_aws_auth"  {
      ~ id       = "825b24ec2d3a1f36c24c4595d9f253591eb996a308a1654ea4a14e93539159be" -> (known after apply)
      ~ rendered = <<-EOT
            apiVersion: v1
            kind: ConfigMap
            metadata:
              name: aws-auth
              namespace: kube-system
            data:
              mapRoles: |
                - rolearn: arn:aws:iam::***:role/prod-midwest-mighty-crab20201014134016318400000005
                  username: system:node:{{EC2PrivateDNSName}}
                  groups:
                    - system:bootstrappers
                    - system:nodes


                - "groups":
                  - "system:masters"
                  "rolearn": "arn:aws:iam::***:role/admin"
                  "username": "admin"
                - "groups":
                  - "system:masters"
                  "rolearn": "arn:aws:iam::***:role/eks-admin"
                  "username": "eks-admin"
                - "groups":
                  - "system:readers"
                  "rolearn": "arn:aws:iam::***:role/administrator"
                  "username": "eks-readonly"
                - "groups":
                  - "system:bootstrappers"
                  - "system:nodes"
                  - "system:node-proxier"
                  "rolearn": "arn:aws:iam::***:role/eks-fargate-pod-executor"
                  "username": "system:node:{{SessionName}}"



              mapUsers: |
                - "groups":
                  - "system:readers"
                  - "team-growflare:admins"
                  - "team-ramble:admins"
                  - "team-thundercats:admins"
                  - "team-warriors:admins"
                  "userarn": "arn:aws:iam::***:user/humans/andrew.bridges"
                  "username": "andrew.bridges"
                - "groups":
                  - "system:readers"
                  "userarn": "arn:aws:iam::***:user/humans/bill.jamison"
                  "username": "bill.jamison"
                - "groups":
                  - "system:readers"
                  "userarn": "arn:aws:iam::***:user/humans/brendan.erwin"
                  "username": "brendan.erwin"
                - "groups":
                  - "system:readers"
                  - "team-service-corps:admins"
                  - "team-service-corps:prodsupport_access"
                  - "team-the-a-team:admins"
                  - "team-thundercats:admins"
                  - "system:masters"
                  - "team-sre:admins"
                  "userarn": "arn:aws:iam::***:user/humans/brian.malinconico"
                  "username": "brian.malinconico"
                - "groups":
                  - "system:readers"
                  - "team-growflare:admins"
                  - "team-ramble:admins"
                  - "team-thundercats:admins"
                  - "team-warriors:admins"
                  "userarn": "arn:aws:iam::***:user/humans/brian.weissler"
                  "username": "brian.weissler"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/chris.vannoy"
                  "username": "chris.vannoy"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/jason.steinhauser"
                  "username": "jason.steinhauser"
                - "groups":
                  - "system:readers"
                  - "team-growflare:admins"
                  - "team-ramble:admins"
                  - "team-thundercats:admins"
                  - "team-warriors:admins"
                  - "team-the-a-team:admins"
                  "userarn": "arn:aws:iam::***:user/humans/john.barton"
                  "username": "john.barton"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/jonathan.ascenci"
                  "username": "jonathan.ascenci"
                - "groups":
                  - "system:readers"
                  - "team-application-backend:admins"
                  - "team-thundercats:admins"
                  - "team-service-corps:prodsupport_access"
                  "userarn": "arn:aws:iam::***:user/humans/matt.miller"
                  "username": "matt.miller"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/patrick.gibbons"
                  "username": "patrick.gibbons"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/robb.phillips"
                  "username": "robb.phillips"
                - "groups":
                  - "system:readers"
                  - "team-emailx-contractors:admins"
                  "userarn": "arn:aws:iam::***:user/humans/sergey.kudryk"
                  "username": "sergey.kudryk"
                - "groups":
                  - "system:readers"
                  - "team-growflare:admins"
                  - "team-ramble:admins"
                  - "team-thundercats:admins"
                  - "team-warriors:admins"
                  - "team-the-a-team:admins"
                  "userarn": "arn:aws:iam::***:user/humans/tyler.hastings"
                  "username": "tyler.hastings"



        EOT -> (known after apply)
      ~ vars     = {
          ~ "worker_role_arn" = <<-EOT
                    - rolearn: arn:aws:iam::***:role/prod-midwest-mighty-crab20201014134016318400000005
                      username: system:node:{{EC2PrivateDNSName}}
                      groups:
                        - system:bootstrappers
                        - system:nodes
            EOT -> (known after apply)
            # (3 unchanged elements hidden)
        }
        # (1 unchanged attribute hidden)
    }

  # module.eks.data.template_file.kubeconfig will be read during apply
  # (config refers to values not yet known)
 <= data "template_file" "kubeconfig"  {
      ~ id       = "2537f0935c2044eba7f6e43bee4a66e3cf9bded2fea1556569e69c6599780c5a" -> (known after apply)
      ~ rendered = <<-EOT
            apiVersion: v1
            preferences: {}
            kind: Config

            clusters:
            - cluster:
                server: https://52802C254287C012F034999E4B36A377.gr7.us-east-1.eks.amazonaws.com
                certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01UQXhOREV6TXpjeE4xb1hEVE13TVRBeE1qRXpNemN4TjFvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBTkc1CllNcmlUZzBia0g2VlZ1TU5rMmUybEI1Vm45TUtMSDJja1hMNzcvK05FZU5tejZnLzJSV2ZZZ0lucnVmY3gxVTEKZG9yQVU5QU1WT0lnLzhLc2lncmhkcHJvQzZBcmR3aElwRi8vcE5JNjRyVGNwZkFKTHBIYTdIM0lZQSthT0kwawo3RDlyaGZzU2N3cXdkRndnN3gxVS84c3lkY1c3ZmIwQzY0TXBubTQ2MnJuSWtsTk5NdnppdEZDVDNtNlNkNy91CkF2RUJJa01IQWpVanZDcE1hLzlHZlYzVmptSzRZbGtIbVZHQ1cwMThzaWNiNDQxa2s4WlZuU3YzNlVzQWQ3SEUKUm9JK0RBSXRSdjlRR0RCcUJsVFZCU2lqbXBhQjM3TktEa0NkWlNMdi96azZ6MUtpbnRaOFVHZ3Qwd3lHKzJUTQpRL3cvWVk0cU1lanBvRWhCSXZrQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFLbFZQQUYrSXcyTUJETnlRRjQ4SGpWSFlHTGEKWXM0RVZUYmRmTGNGVFB2Q0JuRnR4bFR1OVBXNjMvOVdqSnRqSlVaQ2xmT21UTGZLRFpyb1c2ZU1xTjZGVm9FUgpNSEJzbjR5RkVaLzBDNkVwbWJNRGhSenBOM25Balk1RldmN3lEdHhWS2tWU01mVm9QSWhORy9nckZqYmY5cDNXCnhyQm9kaWtzKzQ2ODNTUktManFhQkJxRVBYT3hOOGd0U3lHMzZNdVZHeVRiZVRDb1RwUDRqUGNDTXN1YU4weXUKd1pXeCtKK1lqVnBmZ2NOMkxHMDBFQTQ2SDVlK0N2NFREcWRjQnVkR0tvYnZXOTNlYW9PcXFQb3B4T3JqY0hvdwpya0ZsVk5QV2paU2Uzbmo1UGFQcFBVZ3YzL0Jnait0c1JkRTM4NkZERTE1N1ZNeUNFUldabHJYd0dJND0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
              name: eks_prod-midwest-mighty-crab

            contexts:
            - context:
                cluster: eks_prod-midwest-mighty-crab
                user: eks_prod-midwest-mighty-crab
              name: eks_prod-midwest-mighty-crab

            current-context: eks_prod-midwest-mighty-crab

            users:
            - name: eks_prod-midwest-mighty-crab
              user:
                exec:
                  apiVersion: client.authentication.k8s.io/v1alpha1
                  command: aws-iam-authenticator
                  args:
                    - "token"
                    - "-i"
                    - "prod-midwest-mighty-crab"


        EOT -> (known after apply)
        # (2 unchanged attributes hidden)
    }

  # module.eks.data.template_file.userdata[0] will be read during apply
  # (config refers to values not yet known)
 <= data "template_file" "userdata"  {
      ~ id       = "89ac0e9d1a05026a8c7f42427f51201350b9e644e1fc670ea23c5eb024eecd17" -> (known after apply)
      ~ rendered = <<-EOT
            #!/bin/bash -xe

            # Allow user supplied pre userdata code


            # Bootstrap and join the cluster
            /etc/eks/bootstrap.sh --b64-cluster-ca 'LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01UQXhOREV6TXpjeE4xb1hEVE13TVRBeE1qRXpNemN4TjFvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBTkc1CllNcmlUZzBia0g2VlZ1TU5rMmUybEI1Vm45TUtMSDJja1hMNzcvK05FZU5tejZnLzJSV2ZZZ0lucnVmY3gxVTEKZG9yQVU5QU1WT0lnLzhLc2lncmhkcHJvQzZBcmR3aElwRi8vcE5JNjRyVGNwZkFKTHBIYTdIM0lZQSthT0kwawo3RDlyaGZzU2N3cXdkRndnN3gxVS84c3lkY1c3ZmIwQzY0TXBubTQ2MnJuSWtsTk5NdnppdEZDVDNtNlNkNy91CkF2RUJJa01IQWpVanZDcE1hLzlHZlYzVmptSzRZbGtIbVZHQ1cwMThzaWNiNDQxa2s4WlZuU3YzNlVzQWQ3SEUKUm9JK0RBSXRSdjlRR0RCcUJsVFZCU2lqbXBhQjM3TktEa0NkWlNMdi96azZ6MUtpbnRaOFVHZ3Qwd3lHKzJUTQpRL3cvWVk0cU1lanBvRWhCSXZrQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFLbFZQQUYrSXcyTUJETnlRRjQ4SGpWSFlHTGEKWXM0RVZUYmRmTGNGVFB2Q0JuRnR4bFR1OVBXNjMvOVdqSnRqSlVaQ2xmT21UTGZLRFpyb1c2ZU1xTjZGVm9FUgpNSEJzbjR5RkVaLzBDNkVwbWJNRGhSenBOM25Balk1RldmN3lEdHhWS2tWU01mVm9QSWhORy9nckZqYmY5cDNXCnhyQm9kaWtzKzQ2ODNTUktManFhQkJxRVBYT3hOOGd0U3lHMzZNdVZHeVRiZVRDb1RwUDRqUGNDTXN1YU4weXUKd1pXeCtKK1lqVnBmZ2NOMkxHMDBFQTQ2SDVlK0N2NFREcWRjQnVkR0tvYnZXOTNlYW9PcXFQb3B4T3JqY0hvdwpya0ZsVk5QV2paU2Uzbmo1UGFQcFBVZ3YzL0Jnait0c1JkRTM4NkZERTE1N1ZNeUNFUldabHJYd0dJND0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=' --apiserver-endpoint 'https://52802C254287C012F034999E4B36A377.gr7.us-east-1.eks.amazonaws.com'  --kubelet-extra-args "" 'prod-midwest-mighty-crab'

            # Allow user supplied userdata code
            # Post EKS bootstrap user-data
            # Increment to trigger rebuilding EKS ASGs: 1

            # Restrict pod access to the ec2 metadata API. Pods should instead prefer to use Service Accounts annotated with AWS Roles.
            # For more information, see https://docs.aws.amazon.com/en_pv/eks/latest/userguide/restrict-ec2-credential-access.html
            yum install -y iptables-services
            iptables --insert FORWARD 1 --in-interface eni+ --destination 169.254.169.254/32 --jump DROP
            iptables-save | tee /etc/sysconfig/iptables
            systemctl enable --now iptables

            # Install SSM
            yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
            systemctl enable --now amazon-ssm-agent

            # Install kubectl
            KUBECTL_VERSION=v1.21.2
            curl -LO https://storage.googleapis.com/kubernetes-release/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl
            chmod +x ./kubectl
            mv ./kubectl /usr/bin/kubectl

            # Create kubectl config
            aws eks --region us-east-1 update-kubeconfig --name prod-midwest-mighty-crab --kubeconfig /opt/kube/config

            # Create the drain-node script
            mkdir -p /opt/scripts
            cat << 'EOF' > /opt/scripts/drain-node.sh
            #!/usr/bin/env bash

            trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM

            REQUESTED_INSTANCE_ID=${1:-none}
            remaining_heartbeat_events=${2:-3}

            INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
            if [[ $REQUESTED_INSTANCE_ID != $INSTANCE_ID ]]; then
              echo "kubectl drain requested for $REQUESTED_INSTANCE_ID, not for $INSTANCE_ID. Exiting..."
              exit 0
            fi

            set -eu

            K8S_NODE=$(curl -s http://169.254.169.254/latest/meta-data/hostname)
            REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//')
            ASG_NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=aws:autoscaling:groupName" --region ${REGION} | jq '.Tags[0].Value' -r)
            CMD_OPTS="--region ${REGION} --auto-scaling-group-name ${ASG_NAME} --lifecycle-hook-name prod-midwest-mighty-crab-worker-node-termination --instance-id ${INSTANCE_ID}"

            HEARTBEAT_TIMEOUT=$(aws autoscaling describe-lifecycle-hooks --region ${REGION} --auto-scaling-group-name ${ASG_NAME} --lifecycle-hook-names prod-midwest-mighty-crab-worker-node-termination | jq '.LifecycleHooks[0].HeartbeatTimeout')
            POLL_EVENTS_UNTIL_HEARTBEAT=$(( $HEARTBEAT_TIMEOUT / 10 - 3 ))

            echo "draining node: $K8S_NODE - $INSTANCE_ID"
            kubectl --kubeconfig='/opt/kube/config' drain --force --ignore-daemonsets --delete-local-data ${K8S_NODE} &
            PROC_ID=$!

            remaining_poll_events=$POLL_EVENTS_UNTIL_HEARTBEAT
            while kill -0 "$PROC_ID" &>/dev/null; do
              ((remaining_poll_events--))

              if (( $remaining_poll_events <= 0 )); then
                if (( $remaining_heartbeat_events <= 0 )); then
                  aws autoscaling complete-lifecycle-action ${CMD_OPTS} --lifecycle-action-result ABORT
                  exit 1
                else
                  aws autoscaling record-lifecycle-action-heartbeat ${CMD_OPTS}
                  ((remaining_heartbeat_events--))
                  remaining_poll_events=$POLL_EVENTS_UNTIL_HEARTBEAT
                fi
              fi

              sleep 10
            done

            aws autoscaling complete-lifecycle-action ${CMD_OPTS} --lifecycle-action-result CONTINUE
            EOF

            chmod +x /opt/scripts/drain-node.sh

        EOT -> (known after apply)
        # (2 unchanged attributes hidden)
    }

  # module.eks.data.template_file.worker_role_arns[0] will be read during apply
  # (config refers to values not yet known)
 <= data "template_file" "worker_role_arns"  {
      ~ id       = "106d45ac8acfeb546dbf236355bf517dfc56aecb51721493cff08f8f76172e23" -> (known after apply)
      ~ rendered = <<-EOT
                - rolearn: arn:aws:iam::***:role/prod-midwest-mighty-crab20201014134016318400000005
                  username: system:node:{{EC2PrivateDNSName}}
                  groups:
                    - system:bootstrappers
                    - system:nodes
        EOT -> (known after apply)
        # (2 unchanged attributes hidden)
    }

  # module.eks.aws_autoscaling_group.workers[0] must be replaced
+/- resource "aws_autoscaling_group" "workers" {
      ~ arn                       = "arn:aws:autoscaling:us-east-1:***:autoScalingGroup:73c861f7-ac27-42f1-a435-c60a3a3217fd:autoScalingGroupName/prod-midwest-mighty-crab-apps-divine-sloth20211116020407529900000002" -> (known after apply)
      ~ availability_zones        = [
          - "us-east-1b",
          - "us-east-1c",
          - "us-east-1d",
        ] -> (known after apply)
      - capacity_rebalance        = false -> null
      ~ default_cooldown          = 300 -> (known after apply)
      - enabled_metrics           = [] -> null
      ~ health_check_type         = "EC2" -> (known after apply)
      ~ id                        = "prod-midwest-mighty-crab-apps-divine-sloth20211116020407529900000002" -> (known after apply)
      ~ launch_configuration      = "prod-midwest-mighty-crab-apps20211116020406559000000001" -> (known after apply)
      - load_balancers            = [] -> null
      - max_instance_lifetime     = 0 -> null
      ~ name                      = "prod-midwest-mighty-crab-apps-divine-sloth20211116020407529900000002" -> (known after apply)
      ~ name_prefix               = "prod-midwest-mighty-crab-apps-divine-sloth" -> (known after apply) # forces replacement
      ~ service_linked_role_arn   = "arn:aws:iam::***:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" -> (known after apply)
      ~ tags                      = [
          + {
              + "key"                 = "karpenter.sh/discovery"
              + "propagate_at_launch" = "true"
              + "value"               = "prod-midwest-mighty-crab"
            },
            # (12 unchanged elements hidden)
        ]
      - target_group_arns         = [] -> null
        # (12 unchanged attributes hidden)

        # (1 unchanged block hidden)
    }

  # module.eks.aws_cloudwatch_log_group.this[0] will be updated in-place
  ~ resource "aws_cloudwatch_log_group" "this" {
        id                = "/aws/eks/prod-midwest-mighty-crab/cluster"
        name              = "/aws/eks/prod-midwest-mighty-crab/cluster"
      ~ tags              = {
          + "karpenter.sh/discovery" = "prod-midwest-mighty-crab"
            # (6 unchanged elements hidden)
        }
      ~ tags_all          = {
          + "karpenter.sh/discovery" = "prod-midwest-mighty-crab"
            # (6 unchanged elements hidden)
        }
        # (2 unchanged attributes hidden)
    }

  # module.eks.aws_iam_policy.worker_autoscaling[0] will be updated in-place
  ~ resource "aws_iam_policy" "worker_autoscaling" {
        id          = "arn:aws:iam::***:policy/eks/eks-worker-autoscaling-prod-midwest-mighty-crab20201014134016343400000007"
        name        = "eks-worker-autoscaling-prod-midwest-mighty-crab20201014134016343400000007"
      ~ policy      = jsonencode(
            {
              - Statement = [
                  - {
                      - Action   = [
                          - "ec2:DescribeLaunchTemplateVersions",
                          - "autoscaling:DescribeTags",
                          - "autoscaling:DescribeLaunchConfigurations",
                          - "autoscaling:DescribeAutoScalingInstances",
                          - "autoscaling:DescribeAutoScalingGroups",
                        ]
                      - Effect   = "Allow"
                      - Resource = "*"
                      - Sid      = "eksWorkerAutoscalingAll"
                    },
                  - {
                      - Action    = [
                          - "autoscaling:UpdateAutoScalingGroup",
                          - "autoscaling:TerminateInstanceInAutoScalingGroup",
                          - "autoscaling:SetDesiredCapacity",
                        ]
                      - Condition = {
                          - StringEquals = {
                              - autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled              = "true"
                              - autoscaling:ResourceTag/kubernetes.io/cluster/prod-midwest-mighty-crab = "owned"
                            }
                        }
                      - Effect    = "Allow"
                      - Resource  = "*"
                      - Sid       = "eksWorkerAutoscalingOwn"
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
        tags        = {}
        # (6 unchanged attributes hidden)
    }

  # module.eks.aws_iam_role.cluster[0] will be updated in-place
  ~ resource "aws_iam_role" "cluster" {
        id                    = "prod-midwest-mighty-crab20201014132921928700000001"
        name                  = "prod-midwest-mighty-crab20201014132921928700000001"
      ~ tags                  = {
          + "karpenter.sh/discovery" = "prod-midwest-mighty-crab"
            # (6 unchanged elements hidden)
        }
      ~ tags_all              = {
          + "karpenter.sh/discovery" = "prod-midwest-mighty-crab"
            # (6 unchanged elements hidden)
        }
        # (9 unchanged attributes hidden)

        # (1 unchanged block hidden)
    }

  # module.eks.aws_iam_role.workers[0] will be updated in-place
  ~ resource "aws_iam_role" "workers" {
        id                    = "prod-midwest-mighty-crab20201014134016318400000005"
        name                  = "prod-midwest-mighty-crab20201014134016318400000005"
      ~ tags                  = {
          + "karpenter.sh/discovery" = "prod-midwest-mighty-crab"
            # (6 unchanged elements hidden)
        }
      ~ tags_all              = {
          + "karpenter.sh/discovery" = "prod-midwest-mighty-crab"
            # (6 unchanged elements hidden)
        }
        # (9 unchanged attributes hidden)

        # (1 unchanged block hidden)
    }

  # module.eks.aws_launch_configuration.workers[0] must be replaced
+/- resource "aws_launch_configuration" "workers" {
      ~ arn                              = "arn:aws:autoscaling:us-east-1:***:launchConfiguration:223aaff3-fb33-47e8-ac0d-82df46010a9a:launchConfigurationName/prod-midwest-mighty-crab-apps20211116020406559000000001" -> (known after apply)
      ~ id                               = "prod-midwest-mighty-crab-apps20211116020406559000000001" -> (known after apply)
      + key_name                         = (known after apply)
      ~ name                             = "prod-midwest-mighty-crab-apps20211116020406559000000001" -> (known after apply)
      ~ user_data_base64                 = "IyEvYmluL2Jhc2ggLXhlCgojIEFsbG93IHVzZXIgc3VwcGxpZWQgcHJlIHVzZXJkYXRhIGNvZGUKCgojIEJvb3RzdHJhcCBhbmQgam9pbiB0aGUgY2x1c3RlcgovZXRjL2Vrcy9ib290c3RyYXAuc2ggLS1iNjQtY2x1c3Rlci1jYSAnTFMwdExTMUNSVWRKVGlCRFJWSlVTVVpKUTBGVVJTMHRMUzB0Q2sxSlNVTjVSRU5EUVdKRFowRjNTVUpCWjBsQ1FVUkJUa0puYTNGb2EybEhPWGN3UWtGUmMwWkJSRUZXVFZKTmQwVlJXVVJXVVZGRVJYZHdjbVJYU213S1kyMDFiR1JIVm5wTlFqUllSRlJKZDAxVVFYaE9SRVY2VFhwamVFNHhiMWhFVkUxM1RWUkJlRTFxUlhwTmVtTjRUakZ2ZDBaVVJWUk5Ra1ZIUVRGVlJRcEJlRTFMWVROV2FWcFlTblZhV0ZKc1kzcERRMEZUU1hkRVVWbEtTMjlhU1doMlkwNUJVVVZDUWxGQlJHZG5SVkJCUkVORFFWRnZRMmRuUlVKQlRrYzFDbGxOY21sVVp6QmlhMGcyVmxaMVRVNXJNbVV5YkVJMVZtNDVUVXRNU0RKamExaE1OemN2SzA1RlpVNXRlalpuTHpKU1YyWlpaMGx1Y25WbVkzZ3hWVEVLWkc5eVFWVTVRVTFXVDBsbkx6aExjMmxuY21oa2NISnZRelpCY21SM2FFbHdSaTh2Y0U1Sk5qUnlWR053WmtGS1RIQklZVGRJTTBsWlFTdGhUMGt3YXdvM1JEbHlhR1p6VTJOM2NYZGtSbmRuTjNneFZTODRjM2xrWTFjM1ptSXdRelkwVFhCdWJUUTJNbkp1U1d0c1RrNU5kbnBwZEVaRFZETnRObE5rTnk5MUNrRjJSVUpKYTAxSVFXcFZhblpEY0UxaEx6bEhabFl6Vm1wdFN6UlpiR3RJYlZaSFExY3dNVGh6YVdOaU5EUXhhMnM0V2xadVUzWXpObFZ6UVdRM1NFVUtVbTlKSzBSQlNYUlNkamxSUjBSQ2NVSnNWRlpDVTJscWJYQmhRak0zVGt0RWEwTmtXbE5NZGk5NmF6WjZNVXRwYm5SYU9GVkhaM1F3ZDNsSEt6SlVUUXBSTDNjdldWazBjVTFsYW5CdlJXaENTWFpyUTBGM1JVRkJZVTFxVFVORmQwUm5XVVJXVWpCUVFWRklMMEpCVVVSQlowdHJUVUU0UjBFeFZXUkZkMFZDQ2k5M1VVWk5RVTFDUVdZNGQwUlJXVXBMYjFwSmFIWmpUa0ZSUlV4Q1VVRkVaMmRGUWtGTGJGWlFRVVlyU1hjeVRVSkVUbmxSUmpRNFNHcFdTRmxIVEdFS1dYTTBSVlpVWW1SbVRHTkdWRkIyUTBKdVJuUjRiRlIxT1ZCWE5qTXZPVmRxU25ScVNsVmFRMnhtVDIxVVRHWkxSRnB5YjFjMlpVMXhUalpHVm05RlVncE5TRUp6YmpSNVJrVmFMekJETmtWd2JXSk5SR2hTZW5CT00yNUJhbGsxUmxkbU4zbEVkSGhXUzJ0V1UwMW1WbTlRU1doT1J5OW5ja1pxWW1ZNWNETlhDbmh5UW05a2FXdHpLelEyT0ROVFVrdE1hbkZoUWtKeFJWQllUM2hPT0dkMFUzbEhNelpOZFZaSGVWUmlaVlJEYjFSd1VEUnFVR05EVFhOMVlVNHdlWFVLZDFwWGVDdEtLMWxxVm5CbVoyTk9Na3hITURCRlFUUTJTRFZsSzBOMk5GUkVjV1JqUW5Wa1IwdHZZblpYT1RObFlXOVBjWEZRYjNCNFQzSnFZMGh2ZHdweWEwWnNWazVRVjJwYVUyVXpibW8xVUdGUWNGQlZaM1l6TDBKbmFpdDBjMUprUlRNNE5rWkVSVEUxTjFaTmVVTkZVbGRhYkhKWWQwZEpORDBLTFMwdExTMUZUa1FnUTBWU1ZFbEdTVU5CVkVVdExTMHRMUW89JyAtLWFwaXNlcnZlci1lbmRwb2ludCAnaHR0cHM6Ly81MjgwMkMyNTQyODdDMDEyRjAzNDk5OUU0QjM2QTM3Ny5ncjcudXMtZWFzdC0xLmVrcy5hbWF6b25hd3MuY29tJyAgLS1rdWJlbGV0LWV4dHJhLWFyZ3MgIiIgJ3Byb2QtbWlkd2VzdC1taWdodHktY3JhYicKCiMgQWxsb3cgdXNlciBzdXBwbGllZCB1c2VyZGF0YSBjb2RlCiMgUG9zdCBFS1MgYm9vdHN0cmFwIHVzZXItZGF0YQojIEluY3JlbWVudCB0byB0cmlnZ2VyIHJlYnVpbGRpbmcgRUtTIEFTR3M6IDEKCiMgUmVzdHJpY3QgcG9kIGFjY2VzcyB0byB0aGUgZWMyIG1ldGFkYXRhIEFQSS4gUG9kcyBzaG91bGQgaW5zdGVhZCBwcmVmZXIgdG8gdXNlIFNlcnZpY2UgQWNjb3VudHMgYW5ub3RhdGVkIHdpdGggQVdTIFJvbGVzLgojIEZvciBtb3JlIGluZm9ybWF0aW9uLCBzZWUgaHR0cHM6Ly9kb2NzLmF3cy5hbWF6b24uY29tL2VuX3B2L2Vrcy9sYXRlc3QvdXNlcmd1aWRlL3Jlc3RyaWN0LWVjMi1jcmVkZW50aWFsLWFjY2Vzcy5odG1sCnl1bSBpbnN0YWxsIC15IGlwdGFibGVzLXNlcnZpY2VzCmlwdGFibGVzIC0taW5zZXJ0IEZPUldBUkQgMSAtLWluLWludGVyZmFjZSBlbmkrIC0tZGVzdGluYXRpb24gMTY5LjI1NC4xNjkuMjU0LzMyIC0tanVtcCBEUk9QCmlwdGFibGVzLXNhdmUgfCB0ZWUgL2V0Yy9zeXNjb25maWcvaXB0YWJsZXMKc3lzdGVtY3RsIGVuYWJsZSAtLW5vdyBpcHRhYmxlcwoKIyBJbnN0YWxsIFNTTQp5dW0gaW5zdGFsbCAteSBodHRwczovL3MzLmFtYXpvbmF3cy5jb20vZWMyLWRvd25sb2Fkcy13aW5kb3dzL1NTTUFnZW50L2xhdGVzdC9saW51eF9hbWQ2NC9hbWF6b24tc3NtLWFnZW50LnJwbQpzeXN0ZW1jdGwgZW5hYmxlIC0tbm93IGFtYXpvbi1zc20tYWdlbnQKCiMgSW5zdGFsbCBrdWJlY3RsCktVQkVDVExfVkVSU0lPTj12MS4yMS4yCmN1cmwgLUxPIGh0dHBzOi8vc3RvcmFnZS5nb29nbGVhcGlzLmNvbS9rdWJlcm5ldGVzLXJlbGVhc2UvcmVsZWFzZS8kS1VCRUNUTF9WRVJTSU9OL2Jpbi9saW51eC9hbWQ2NC9rdWJlY3RsCmNobW9kICt4IC4va3ViZWN0bAptdiAuL2t1YmVjdGwgL3Vzci9iaW4va3ViZWN0bAoKIyBDcmVhdGUga3ViZWN0bCBjb25maWcKYXdzIGVrcyAtLXJlZ2lvbiB1cy1lYXN0LTEgdXBkYXRlLWt1YmVjb25maWcgLS1uYW1lIHByb2QtbWlkd2VzdC1taWdodHktY3JhYiAtLWt1YmVjb25maWcgL29wdC9rdWJlL2NvbmZpZwoKIyBDcmVhdGUgdGhlIGRyYWluLW5vZGUgc2NyaXB0Cm1rZGlyIC1wIC9vcHQvc2NyaXB0cwpjYXQgPDwgJ0VPRicgPiAvb3B0L3NjcmlwdHMvZHJhaW4tbm9kZS5zaAojIS91c3IvYmluL2VudiBiYXNoCgp0cmFwICJ0cmFwIC0gU0lHVEVSTSAmJiBraWxsIC0tIC0kJCIgU0lHSU5UIFNJR1RFUk0KClJFUVVFU1RFRF9JTlNUQU5DRV9JRD0kezE6LW5vbmV9CnJlbWFpbmluZ19oZWFydGJlYXRfZXZlbnRzPSR7MjotM30KCklOU1RBTkNFX0lEPSQoY3VybCAtcyBodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvaW5zdGFuY2UtaWQpCmlmIFtbICRSRVFVRVNURURfSU5TVEFOQ0VfSUQgIT0gJElOU1RBTkNFX0lEIF1dOyB0aGVuCiAgZWNobyAia3ViZWN0bCBkcmFpbiByZXF1ZXN0ZWQgZm9yICRSRVFVRVNURURfSU5TVEFOQ0VfSUQsIG5vdCBmb3IgJElOU1RBTkNFX0lELiBFeGl0aW5nLi4uIgogIGV4aXQgMApmaQoKc2V0IC1ldQoKSzhTX05PREU9JChjdXJsIC1zIGh0dHA6Ly8xNjkuMjU0LjE2OS4yNTQvbGF0ZXN0L21ldGEtZGF0YS9ob3N0bmFtZSkKUkVHSU9OPSQoY3VybCAtcyBodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2xhdGVzdC9tZXRhLWRhdGEvcGxhY2VtZW50L2F2YWlsYWJpbGl0eS16b25lIHwgc2VkICdzL1thLXpdJC8vJykKQVNHX05BTUU9JChhd3MgZWMyIGRlc2NyaWJlLXRhZ3MgLS1maWx0ZXJzICJOYW1lPXJlc291cmNlLWlkLFZhbHVlcz0ke0lOU1RBTkNFX0lEfSIgIk5hbWU9a2V5LFZhbHVlcz1hd3M6YXV0b3NjYWxpbmc6Z3JvdXBOYW1lIiAtLXJlZ2lvbiAke1JFR0lPTn0gfCBqcSAnLlRhZ3NbMF0uVmFsdWUnIC1yKQpDTURfT1BUUz0iLS1yZWdpb24gJHtSRUdJT059IC0tYXV0by1zY2FsaW5nLWdyb3VwLW5hbWUgJHtBU0dfTkFNRX0gLS1saWZlY3ljbGUtaG9vay1uYW1lIHByb2QtbWlkd2VzdC1taWdodHktY3JhYi13b3JrZXItbm9kZS10ZXJtaW5hdGlvbiAtLWluc3RhbmNlLWlkICR7SU5TVEFOQ0VfSUR9IgoKSEVBUlRCRUFUX1RJTUVPVVQ9JChhd3MgYXV0b3NjYWxpbmcgZGVzY3JpYmUtbGlmZWN5Y2xlLWhvb2tzIC0tcmVnaW9uICR7UkVHSU9OfSAtLWF1dG8tc2NhbGluZy1ncm91cC1uYW1lICR7QVNHX05BTUV9IC0tbGlmZWN5Y2xlLWhvb2stbmFtZXMgcHJvZC1taWR3ZXN0LW1pZ2h0eS1jcmFiLXdvcmtlci1ub2RlLXRlcm1pbmF0aW9uIHwganEgJy5MaWZlY3ljbGVIb29rc1swXS5IZWFydGJlYXRUaW1lb3V0JykKUE9MTF9FVkVOVFNfVU5USUxfSEVBUlRCRUFUPSQoKCAkSEVBUlRCRUFUX1RJTUVPVVQgLyAxMCAtIDMgKSkKCmVjaG8gImRyYWluaW5nIG5vZGU6ICRLOFNfTk9ERSAtICRJTlNUQU5DRV9JRCIKa3ViZWN0bCAtLWt1YmVjb25maWc9Jy9vcHQva3ViZS9jb25maWcnIGRyYWluIC0tZm9yY2UgLS1pZ25vcmUtZGFlbW9uc2V0cyAtLWRlbGV0ZS1sb2NhbC1kYXRhICR7SzhTX05PREV9ICYKUFJPQ19JRD0kIQoKcmVtYWluaW5nX3BvbGxfZXZlbnRzPSRQT0xMX0VWRU5UU19VTlRJTF9IRUFSVEJFQVQKd2hpbGUga2lsbCAtMCAiJFBST0NfSUQiICY+L2Rldi9udWxsOyBkbwogICgocmVtYWluaW5nX3BvbGxfZXZlbnRzLS0pKQoKICBpZiAoKCAkcmVtYWluaW5nX3BvbGxfZXZlbnRzIDw9IDAgKSk7IHRoZW4KICAgIGlmICgoICRyZW1haW5pbmdfaGVhcnRiZWF0X2V2ZW50cyA8PSAwICkpOyB0aGVuCiAgICAgIGF3cyBhdXRvc2NhbGluZyBjb21wbGV0ZS1saWZlY3ljbGUtYWN0aW9uICR7Q01EX09QVFN9IC0tbGlmZWN5Y2xlLWFjdGlvbi1yZXN1bHQgQUJPUlQKICAgICAgZXhpdCAxCiAgICBlbHNlCiAgICAgIGF3cyBhdXRvc2NhbGluZyByZWNvcmQtbGlmZWN5Y2xlLWFjdGlvbi1oZWFydGJlYXQgJHtDTURfT1BUU30KICAgICAgKChyZW1haW5pbmdfaGVhcnRiZWF0X2V2ZW50cy0tKSkKICAgICAgcmVtYWluaW5nX3BvbGxfZXZlbnRzPSRQT0xMX0VWRU5UU19VTlRJTF9IRUFSVEJFQVQKICAgIGZpCiAgZmkKCiAgc2xlZXAgMTAKZG9uZQoKYXdzIGF1dG9zY2FsaW5nIGNvbXBsZXRlLWxpZmVjeWNsZS1hY3Rpb24gJHtDTURfT1BUU30gLS1saWZlY3ljbGUtYWN0aW9uLXJlc3VsdCBDT05USU5VRQpFT0YKCmNobW9kICt4IC9vcHQvc2NyaXB0cy9kcmFpbi1ub2RlLnNoCgo=" -> (known after apply) # forces replacement
      - vpc_classic_link_security_groups = [] -> null
        # (8 unchanged attributes hidden)

      + ebs_block_device {
          + delete_on_termination = (known after apply)
          + device_name           = (known after apply)
          + encrypted             = (known after apply)
          + iops                  = (known after apply)
          + no_device             = (known after apply)
          + snapshot_id           = (known after apply)
          + throughput            = (known after apply)
          + volume_size           = (known after apply)
          + volume_type           = (known after apply)
        }

      + metadata_options {
          + http_endpoint               = (known after apply)
          + http_put_response_hop_limit = (known after apply)
          + http_tokens                 = (known after apply)
        }

      ~ root_block_device {
          ~ throughput            = 0 -> (known after apply)
            # (5 unchanged attributes hidden)
        }
    }

  # module.eks.aws_security_group.cluster[0] will be updated in-place
  ~ resource "aws_security_group" "cluster" {
        id                     = "sg-091ec20585b4dadc2"
        name                   = "prod-midwest-mighty-crab20201014132924932200000004"
      ~ tags                   = {
          + "karpenter.sh/discovery" = "prod-midwest-mighty-crab"
            # (7 unchanged elements hidden)
        }
      ~ tags_all               = {
          + "karpenter.sh/discovery" = "prod-midwest-mighty-crab"
            # (7 unchanged elements hidden)
        }
        # (8 unchanged attributes hidden)
    }

  # module.eks.aws_security_group.workers[0] will be updated in-place
  ~ resource "aws_security_group" "workers" {
        id                     = "sg-0a85a7dc1373ecf6b"
        name                   = "prod-midwest-mighty-crab20201014134016335300000006"
      ~ tags                   = {
          + "karpenter.sh/discovery"                         = "prod-midwest-mighty-crab"
            # (8 unchanged elements hidden)
        }
      ~ tags_all               = {
          + "karpenter.sh/discovery"                         = "prod-midwest-mighty-crab"
            # (8 unchanged elements hidden)
        }
        # (8 unchanged attributes hidden)
    }

  # module.eks.random_pet.workers[0] must be replaced
+/- resource "random_pet" "workers" {
      ~ id        = "divine-sloth" -> (known after apply)
      ~ keepers   = {
          - "lc_name" = "prod-midwest-mighty-crab-apps20211116020406559000000001"
        } -> (known after apply) # forces replacement
        # (2 unchanged attributes hidden)
    }

  # module.eks_namespace_botkube.data.aws_iam_policy_document.irsa_arp[0] will be read during apply
  # (config refers to values not yet known)
 <= data "aws_iam_policy_document" "irsa_arp"  {
      ~ id      = "92955526" -> (known after apply)
      ~ json    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:botkube:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
      - version = "2012-10-17" -> null

      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
          - resources     = [] -> null
            # (2 unchanged attributes hidden)


            # (2 unchanged blocks hidden)
        }
    }

  # module.eks_namespace_botkube.data.github_team.namespace_owners[0] will be read during apply
  # (config refers to values not yet known)
 <= data "github_team" "namespace_owners"  {
      ~ description  = "SRE/Core" -> (known after apply)
      ~ id           = "2738563" -> (known after apply)
      ~ members      = [
          - "jcogilvie",
          - "bmalinconico",
          - "xStatick",
          - "cduddikunta",
          - "dreinhardt-terminus",
        ] -> (known after apply)
      ~ name         = "SRE" -> (known after apply)
      ~ node_id      = "MDQ6VGVhbTI3Mzg1NjM=" -> (known after apply)
      ~ permission   = "pull" -> (known after apply)
      ~ privacy      = "closed" -> (known after apply)
      ~ repositories = [
          - "bff-monitors",
          - "blinkin-lights",
          - "buildbox-infra",
          - "chat-mqtt-infra",
          - "cou-config-service",
          - "cou-config-service-infra",
          - "creative_asset_library_infra",
          - "customer_entitlements_infra",
          - "devro-infra",
          - "drone-ci",
          - "drone-terraform",
          - "eks-infra",
          - "engagement-metrics-infra",
          - "entitlements_exporter_infra",
          - "envoy-alpine-base",
          - "envoy-convox-sds",
          - "external_webhook_delivery_infra",
          - "federated-infra-template",
          - "helm-charts",
          - "infra-terminus-ninja",
          - "java-ci-image",
          - "linkedin_service_infra",
          - "monitor-dashboard",
          - "my_terminus_infra",
          - "ninja-mailcatcher",
          - "notification_service_infra",
          - "orb-domain-lookup-infra",
          - "platform-browser-identity",
          - "platform-browser-identity-infra",
          - "platform-users-infra",
          - "ramble-infra",
          - "s3helper",
          - "semi_trusted_entity_proxy_infra",
          - "sigstr-devops",
          - "slackbot",
          - "soylent-green",
          - "sre-suggestion-box",
          - "terminus-github-actions",
          - "terraform-aws-eks",
          - "terraform-docker",
          - "terraform-midwest",
          - "terraform-modules-midwest",
          - "terraform-provider-couconfig",
          - "terraform-provider-kubernetes",
          - "web-event-capture-infra",
          - "web_tracking",
        ] -> (known after apply)
        # (1 unchanged attribute hidden)
    }

  # module.eks_namespace_cert_manager.data.aws_iam_policy_document.irsa_arp[0] will be read during apply
  # (config refers to values not yet known)
 <= data "aws_iam_policy_document" "irsa_arp"  {
      ~ id      = "2296982326" -> (known after apply)
      ~ json    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:cert-manager:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
      - version = "2012-10-17" -> null

      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
          - resources     = [] -> null
            # (2 unchanged attributes hidden)


            # (2 unchanged blocks hidden)
        }
    }

  # module.eks_namespace_linkerd.data.aws_iam_policy_document.irsa_arp[0] will be read during apply
  # (config refers to values not yet known)
 <= data "aws_iam_policy_document" "irsa_arp"  {
      ~ id      = "508379009" -> (known after apply)
      ~ json    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:linkerd:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
      - version = "2012-10-17" -> null

      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
          - resources     = [] -> null
            # (2 unchanged attributes hidden)


            # (2 unchanged blocks hidden)
        }
    }

  # module.eks_namespace_linkerd_cni.data.aws_iam_policy_document.irsa_arp[0] will be read during apply
  # (config refers to values not yet known)
 <= data "aws_iam_policy_document" "irsa_arp"  {
      ~ id      = "8469501" -> (known after apply)
      ~ json    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:linkerd-cni:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
      - version = "2012-10-17" -> null

      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
          - resources     = [] -> null
            # (2 unchanged attributes hidden)


            # (2 unchanged blocks hidden)
        }
    }

  # module.eks_namespace_linkerd_cni.data.github_team.namespace_owners[0] will be read during apply
  # (config refers to values not yet known)
 <= data "github_team" "namespace_owners"  {
      ~ description  = "SRE/Core" -> (known after apply)
      ~ id           = "2738563" -> (known after apply)
      ~ members      = [
          - "jcogilvie",
          - "bmalinconico",
          - "xStatick",
          - "cduddikunta",
          - "dreinhardt-terminus",
        ] -> (known after apply)
      ~ name         = "SRE" -> (known after apply)
      ~ node_id      = "MDQ6VGVhbTI3Mzg1NjM=" -> (known after apply)
      ~ permission   = "pull" -> (known after apply)
      ~ privacy      = "closed" -> (known after apply)
      ~ repositories = [
          - "bff-monitors",
          - "blinkin-lights",
          - "buildbox-infra",
          - "chat-mqtt-infra",
          - "cou-config-service",
          - "cou-config-service-infra",
          - "creative_asset_library_infra",
          - "customer_entitlements_infra",
          - "devro-infra",
          - "drone-ci",
          - "drone-terraform",
          - "eks-infra",
          - "engagement-metrics-infra",
          - "entitlements_exporter_infra",
          - "envoy-alpine-base",
          - "envoy-convox-sds",
          - "external_webhook_delivery_infra",
          - "federated-infra-template",
          - "helm-charts",
          - "infra-terminus-ninja",
          - "java-ci-image",
          - "linkedin_service_infra",
          - "monitor-dashboard",
          - "my_terminus_infra",
          - "ninja-mailcatcher",
          - "notification_service_infra",
          - "orb-domain-lookup-infra",
          - "platform-browser-identity",
          - "platform-browser-identity-infra",
          - "platform-users-infra",
          - "ramble-infra",
          - "s3helper",
          - "semi_trusted_entity_proxy_infra",
          - "sigstr-devops",
          - "slackbot",
          - "soylent-green",
          - "sre-suggestion-box",
          - "terminus-github-actions",
          - "terraform-aws-eks",
          - "terraform-docker",
          - "terraform-midwest",
          - "terraform-modules-midwest",
          - "terraform-provider-couconfig",
          - "terraform-provider-kubernetes",
          - "web-event-capture-infra",
          - "web_tracking",
        ] -> (known after apply)
        # (1 unchanged attribute hidden)
    }

  # module.eks_namespace_linkerd_viz.data.aws_iam_policy_document.irsa_arp[0] will be read during apply
  # (config refers to values not yet known)
 <= data "aws_iam_policy_document" "irsa_arp"  {
      ~ id      = "1696330123" -> (known after apply)
      ~ json    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:linkerd-dashboard:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
      - version = "2012-10-17" -> null

      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
          - resources     = [] -> null
            # (2 unchanged attributes hidden)


            # (2 unchanged blocks hidden)
        }
    }

  # module.eks_namespace_linkerd_viz.data.github_team.namespace_owners[0] will be read during apply
  # (config refers to values not yet known)
 <= data "github_team" "namespace_owners"  {
      ~ description  = "SRE/Core" -> (known after apply)
      ~ id           = "2738563" -> (known after apply)
      ~ members      = [
          - "jcogilvie",
          - "bmalinconico",
          - "xStatick",
          - "cduddikunta",
          - "dreinhardt-terminus",
        ] -> (known after apply)
      ~ name         = "SRE" -> (known after apply)
      ~ node_id      = "MDQ6VGVhbTI3Mzg1NjM=" -> (known after apply)
      ~ permission   = "pull" -> (known after apply)
      ~ privacy      = "closed" -> (known after apply)
      ~ repositories = [
          - "bff-monitors",
          - "blinkin-lights",
          - "buildbox-infra",
          - "chat-mqtt-infra",
          - "cou-config-service",
          - "cou-config-service-infra",
          - "creative_asset_library_infra",
          - "customer_entitlements_infra",
          - "devro-infra",
          - "drone-ci",
          - "drone-terraform",
          - "eks-infra",
          - "engagement-metrics-infra",
          - "entitlements_exporter_infra",
          - "envoy-alpine-base",
          - "envoy-convox-sds",
          - "external_webhook_delivery_infra",
          - "federated-infra-template",
          - "helm-charts",
          - "infra-terminus-ninja",
          - "java-ci-image",
          - "linkedin_service_infra",
          - "monitor-dashboard",
          - "my_terminus_infra",
          - "ninja-mailcatcher",
          - "notification_service_infra",
          - "orb-domain-lookup-infra",
          - "platform-browser-identity",
          - "platform-browser-identity-infra",
          - "platform-users-infra",
          - "ramble-infra",
          - "s3helper",
          - "semi_trusted_entity_proxy_infra",
          - "sigstr-devops",
          - "slackbot",
          - "soylent-green",
          - "sre-suggestion-box",
          - "terminus-github-actions",
          - "terraform-aws-eks",
          - "terraform-docker",
          - "terraform-midwest",
          - "terraform-modules-midwest",
          - "terraform-provider-couconfig",
          - "terraform-provider-kubernetes",
          - "web-event-capture-infra",
          - "web_tracking",
        ] -> (known after apply)
        # (1 unchanged attribute hidden)
    }

  # module.eks_namespace_terminus_system.data.aws_iam_policy_document.irsa_arp[0] will be read during apply
  # (config refers to values not yet known)
 <= data "aws_iam_policy_document" "irsa_arp"  {
      ~ id      = "3724886838" -> (known after apply)
      ~ json    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:terminus-system:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
      - version = "2012-10-17" -> null

      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
          - resources     = [] -> null
            # (2 unchanged attributes hidden)


            # (2 unchanged blocks hidden)
        }
    }

  # module.eks_namespace_traefik.data.aws_iam_policy_document.irsa_arp[0] will be read during apply
  # (config refers to values not yet known)
 <= data "aws_iam_policy_document" "irsa_arp"  {
      ~ id      = "3390182712" -> (known after apply)
      ~ json    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:traefik:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
      - version = "2012-10-17" -> null

      ~ statement {
          - not_actions   = [] -> null
          - not_resources = [] -> null
          - resources     = [] -> null
            # (2 unchanged attributes hidden)


            # (2 unchanged blocks hidden)
        }
    }

  # module.eks_vpc.aws_subnet.private[0] will be updated in-place
  ~ resource "aws_subnet" "private" {
        id                                             = "subnet-0dd47e406fc214453"
      ~ tags                                           = {
          + "karpenter.sh/discovery"                         = "prod-midwest-mighty-crab"
            # (9 unchanged elements hidden)
        }
      ~ tags_all                                       = {
          + "karpenter.sh/discovery"                         = "prod-midwest-mighty-crab"
            # (9 unchanged elements hidden)
        }
        # (14 unchanged attributes hidden)
    }

  # module.eks_vpc.aws_subnet.private[1] will be updated in-place
  ~ resource "aws_subnet" "private" {
        id                                             = "subnet-04c14856ef9593c5a"
      ~ tags                                           = {
          + "karpenter.sh/discovery"                         = "prod-midwest-mighty-crab"
            # (9 unchanged elements hidden)
        }
      ~ tags_all                                       = {
          + "karpenter.sh/discovery"                         = "prod-midwest-mighty-crab"
            # (9 unchanged elements hidden)
        }
        # (14 unchanged attributes hidden)
    }

  # module.eks_vpc.aws_subnet.private[2] will be updated in-place
  ~ resource "aws_subnet" "private" {
        id                                             = "subnet-0c945c0315bb9c9ad"
      ~ tags                                           = {
          + "karpenter.sh/discovery"                         = "prod-midwest-mighty-crab"
            # (9 unchanged elements hidden)
        }
      ~ tags_all                                       = {
          + "karpenter.sh/discovery"                         = "prod-midwest-mighty-crab"
            # (9 unchanged elements hidden)
        }
        # (14 unchanged attributes hidden)
    }

  # module.external_dns_terminusplatform.aws_iam_role.external_dns[0] will be updated in-place
  ~ resource "aws_iam_role" "external_dns" {
      ~ assume_role_policy    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:terminus-system:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
        id                    = "terminusplatform-external-dns"
        name                  = "terminusplatform-external-dns"
        tags                  = {
            "DeploymentName" = "EKS"
            "Environment"    = "Production"
            "ManagedBy"      = "https://github.com/GetTerminus/eks-infra"
            "ServiceName"    = "EKS"
            "Shared"         = "True"
            "Team"           = "SRE"
        }
        # (9 unchanged attributes hidden)

        # (1 unchanged block hidden)
    }

  # module.external_dns_terminustools.aws_iam_role.external_dns[0] will be updated in-place
  ~ resource "aws_iam_role" "external_dns" {
      ~ assume_role_policy    = jsonencode(
            {
              - Statement = [
                  - {
                      - Action    = "sts:AssumeRoleWithWebIdentity"
                      - Condition = {
                          - StringLike = {
                              - oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377:sub = "system:serviceaccount:terminus-system:*"
                            }
                        }
                      - Effect    = "Allow"
                      - Principal = {
                          - Federated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/52802C254287C012F034999E4B36A377"
                        }
                      - Sid       = ""
                    },
                ]
              - Version   = "2012-10-17"
            }
        ) -> (known after apply)
        id                    = "terminustools-external-dns"
        name                  = "terminustools-external-dns"
        tags                  = {
            "DeploymentName" = "EKS"
            "Environment"    = "Production"
            "ManagedBy"      = "https://github.com/GetTerminus/eks-infra"
            "ServiceName"    = "EKS"
            "Shared"         = "True"
            "Team"           = "SRE"
        }
        # (9 unchanged attributes hidden)

        # (1 unchanged block hidden)
    }

Plan: 3 to add, 14 to change, 3 to destroy.

Changes to Outputs:
  ~ eks = {
      ~ config_map_aws_auth                     = <<-EOT
            apiVersion: v1
            kind: ConfigMap
            metadata:
              name: aws-auth
              namespace: kube-system
            data:
              mapRoles: |
                - rolearn: arn:aws:iam::***:role/prod-midwest-mighty-crab20201014134016318400000005
                  username: system:node:{{EC2PrivateDNSName}}
                  groups:
                    - system:bootstrappers
                    - system:nodes


                - "groups":
                  - "system:masters"
                  "rolearn": "arn:aws:iam::***:role/admin"
                  "username": "admin"
                - "groups":
                  - "system:masters"
                  "rolearn": "arn:aws:iam::***:role/eks-admin"
                  "username": "eks-admin"
                - "groups":
                  - "system:readers"
                  "rolearn": "arn:aws:iam::***:role/administrator"
                  "username": "eks-readonly"
                - "groups":
                  - "system:bootstrappers"
                  - "system:nodes"
                  - "system:node-proxier"
                  "rolearn": "arn:aws:iam::***:role/eks-fargate-pod-executor"
                  "username": "system:node:{{SessionName}}"



              mapUsers: |
                - "groups":
                  - "system:readers"
                  - "team-growflare:admins"
                  - "team-ramble:admins"
                  - "team-thundercats:admins"
                  - "team-warriors:admins"
                  "userarn": "arn:aws:iam::***:user/humans/andrew.bridges"
                  "username": "andrew.bridges"
                - "groups":
                  - "system:readers"
                  "userarn": "arn:aws:iam::***:user/humans/bill.jamison"
                  "username": "bill.jamison"
                - "groups":
                  - "system:readers"
                  "userarn": "arn:aws:iam::***:user/humans/brendan.erwin"
                  "username": "brendan.erwin"
                - "groups":
                  - "system:readers"
                  - "team-service-corps:admins"
                  - "team-service-corps:prodsupport_access"
                  - "team-the-a-team:admins"
                  - "team-thundercats:admins"
                  - "system:masters"
                  - "team-sre:admins"
                  "userarn": "arn:aws:iam::***:user/humans/brian.malinconico"
                  "username": "brian.malinconico"
                - "groups":
                  - "system:readers"
                  - "team-growflare:admins"
                  - "team-ramble:admins"
                  - "team-thundercats:admins"
                  - "team-warriors:admins"
                  "userarn": "arn:aws:iam::***:user/humans/brian.weissler"
                  "username": "brian.weissler"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/chris.vannoy"
                  "username": "chris.vannoy"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/jason.steinhauser"
                  "username": "jason.steinhauser"
                - "groups":
                  - "system:readers"
                  - "team-growflare:admins"
                  - "team-ramble:admins"
                  - "team-thundercats:admins"
                  - "team-warriors:admins"
                  - "team-the-a-team:admins"
                  "userarn": "arn:aws:iam::***:user/humans/john.barton"
                  "username": "john.barton"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/jonathan.ascenci"
                  "username": "jonathan.ascenci"
                - "groups":
                  - "system:readers"
                  - "team-application-backend:admins"
                  - "team-thundercats:admins"
                  - "team-service-corps:prodsupport_access"
                  "userarn": "arn:aws:iam::***:user/humans/matt.miller"
                  "username": "matt.miller"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/patrick.gibbons"
                  "username": "patrick.gibbons"
                - "groups":
                  - "system:readers"
                  - "team-rolling-thunder:admins"
                  "userarn": "arn:aws:iam::***:user/humans/robb.phillips"
                  "username": "robb.phillips"
                - "groups":
                  - "system:readers"
                  - "team-emailx-contractors:admins"
                  "userarn": "arn:aws:iam::***:user/humans/sergey.kudryk"
                  "username": "sergey.kudryk"
                - "groups":
                  - "system:readers"
                  - "team-growflare:admins"
                  - "team-ramble:admins"
                  - "team-thundercats:admins"
                  - "team-warriors:admins"
                  - "team-the-a-team:admins"
                  "userarn": "arn:aws:iam::***:user/humans/tyler.hastings"
                  "username": "tyler.hastings"



        EOT -> (known after apply)
      ~ kubeconfig                              = <<-EOT
            apiVersion: v1
            preferences: {}
            kind: Config

            clusters:
            - cluster:
                server: https://52802C254287C012F034999E4B36A377.gr7.us-east-1.eks.amazonaws.com
                certificate-authority-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01UQXhOREV6TXpjeE4xb1hEVE13TVRBeE1qRXpNemN4TjFvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBTkc1CllNcmlUZzBia0g2VlZ1TU5rMmUybEI1Vm45TUtMSDJja1hMNzcvK05FZU5tejZnLzJSV2ZZZ0lucnVmY3gxVTEKZG9yQVU5QU1WT0lnLzhLc2lncmhkcHJvQzZBcmR3aElwRi8vcE5JNjRyVGNwZkFKTHBIYTdIM0lZQSthT0kwawo3RDlyaGZzU2N3cXdkRndnN3gxVS84c3lkY1c3ZmIwQzY0TXBubTQ2MnJuSWtsTk5NdnppdEZDVDNtNlNkNy91CkF2RUJJa01IQWpVanZDcE1hLzlHZlYzVmptSzRZbGtIbVZHQ1cwMThzaWNiNDQxa2s4WlZuU3YzNlVzQWQ3SEUKUm9JK0RBSXRSdjlRR0RCcUJsVFZCU2lqbXBhQjM3TktEa0NkWlNMdi96azZ6MUtpbnRaOFVHZ3Qwd3lHKzJUTQpRL3cvWVk0cU1lanBvRWhCSXZrQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFLbFZQQUYrSXcyTUJETnlRRjQ4SGpWSFlHTGEKWXM0RVZUYmRmTGNGVFB2Q0JuRnR4bFR1OVBXNjMvOVdqSnRqSlVaQ2xmT21UTGZLRFpyb1c2ZU1xTjZGVm9FUgpNSEJzbjR5RkVaLzBDNkVwbWJNRGhSenBOM25Balk1RldmN3lEdHhWS2tWU01mVm9QSWhORy9nckZqYmY5cDNXCnhyQm9kaWtzKzQ2ODNTUktManFhQkJxRVBYT3hOOGd0U3lHMzZNdVZHeVRiZVRDb1RwUDRqUGNDTXN1YU4weXUKd1pXeCtKK1lqVnBmZ2NOMkxHMDBFQTQ2SDVlK0N2NFREcWRjQnVkR0tvYnZXOTNlYW9PcXFQb3B4T3JqY0hvdwpya0ZsVk5QV2paU2Uzbmo1UGFQcFBVZ3YzL0Jnait0c1JkRTM4NkZERTE1N1ZNeUNFUldabHJYd0dJND0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=
              name: eks_prod-midwest-mighty-crab

            contexts:
            - context:
                cluster: eks_prod-midwest-mighty-crab
                user: eks_prod-midwest-mighty-crab
              name: eks_prod-midwest-mighty-crab

            current-context: eks_prod-midwest-mighty-crab

            users:
            - name: eks_prod-midwest-mighty-crab
              user:
                exec:
                  apiVersion: client.authentication.k8s.io/v1alpha1
                  command: aws-iam-authenticator
                  args:
                    - "token"
                    - "-i"
                    - "prod-midwest-mighty-crab"


        EOT -> (known after apply)
      ~ workers_asg_arns                        = [
          - "arn:aws:autoscaling:us-east-1:***:autoScalingGroup:73c861f7-ac27-42f1-a435-c60a3a3217fd:autoScalingGroupName/prod-midwest-mighty-crab-apps-divine-sloth20211116020407529900000002",
          + (known after apply),
        ]
      ~ workers_asg_names                       = [
          - "prod-midwest-mighty-crab-apps-divine-sloth20211116020407529900000002",
          + (known after apply),
        ]
      ~ workers_user_data                       = [
          - <<-EOT
                #!/bin/bash -xe

                # Allow user supplied pre userdata code


                # Bootstrap and join the cluster
                /etc/eks/bootstrap.sh --b64-cluster-ca 'LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUN5RENDQWJDZ0F3SUJBZ0lCQURBTkJna3Foa2lHOXcwQkFRc0ZBREFWTVJNd0VRWURWUVFERXdwcmRXSmwKY201bGRHVnpNQjRYRFRJd01UQXhOREV6TXpjeE4xb1hEVE13TVRBeE1qRXpNemN4TjFvd0ZURVRNQkVHQTFVRQpBeE1LYTNWaVpYSnVaWFJsY3pDQ0FTSXdEUVlKS29aSWh2Y05BUUVCQlFBRGdnRVBBRENDQVFvQ2dnRUJBTkc1CllNcmlUZzBia0g2VlZ1TU5rMmUybEI1Vm45TUtMSDJja1hMNzcvK05FZU5tejZnLzJSV2ZZZ0lucnVmY3gxVTEKZG9yQVU5QU1WT0lnLzhLc2lncmhkcHJvQzZBcmR3aElwRi8vcE5JNjRyVGNwZkFKTHBIYTdIM0lZQSthT0kwawo3RDlyaGZzU2N3cXdkRndnN3gxVS84c3lkY1c3ZmIwQzY0TXBubTQ2MnJuSWtsTk5NdnppdEZDVDNtNlNkNy91CkF2RUJJa01IQWpVanZDcE1hLzlHZlYzVmptSzRZbGtIbVZHQ1cwMThzaWNiNDQxa2s4WlZuU3YzNlVzQWQ3SEUKUm9JK0RBSXRSdjlRR0RCcUJsVFZCU2lqbXBhQjM3TktEa0NkWlNMdi96azZ6MUtpbnRaOFVHZ3Qwd3lHKzJUTQpRL3cvWVk0cU1lanBvRWhCSXZrQ0F3RUFBYU1qTUNFd0RnWURWUjBQQVFIL0JBUURBZ0trTUE4R0ExVWRFd0VCCi93UUZNQU1CQWY4d0RRWUpLb1pJaHZjTkFRRUxCUUFEZ2dFQkFLbFZQQUYrSXcyTUJETnlRRjQ4SGpWSFlHTGEKWXM0RVZUYmRmTGNGVFB2Q0JuRnR4bFR1OVBXNjMvOVdqSnRqSlVaQ2xmT21UTGZLRFpyb1c2ZU1xTjZGVm9FUgpNSEJzbjR5RkVaLzBDNkVwbWJNRGhSenBOM25Balk1RldmN3lEdHhWS2tWU01mVm9QSWhORy9nckZqYmY5cDNXCnhyQm9kaWtzKzQ2ODNTUktManFhQkJxRVBYT3hOOGd0U3lHMzZNdVZHeVRiZVRDb1RwUDRqUGNDTXN1YU4weXUKd1pXeCtKK1lqVnBmZ2NOMkxHMDBFQTQ2SDVlK0N2NFREcWRjQnVkR0tvYnZXOTNlYW9PcXFQb3B4T3JqY0hvdwpya0ZsVk5QV2paU2Uzbmo1UGFQcFBVZ3YzL0Jnait0c1JkRTM4NkZERTE1N1ZNeUNFUldabHJYd0dJND0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo=' --apiserver-endpoint 'https://52802C254287C012F034999E4B36A377.gr7.us-east-1.eks.amazonaws.com'  --kubelet-extra-args "" 'prod-midwest-mighty-crab'

                # Allow user supplied userdata code
                # Post EKS bootstrap user-data
                # Increment to trigger rebuilding EKS ASGs: 1

                # Restrict pod access to the ec2 metadata API. Pods should instead prefer to use Service Accounts annotated with AWS Roles.
                # For more information, see https://docs.aws.amazon.com/en_pv/eks/latest/userguide/restrict-ec2-credential-access.html
                yum install -y iptables-services
                iptables --insert FORWARD 1 --in-interface eni+ --destination 169.254.169.254/32 --jump DROP
                iptables-save | tee /etc/sysconfig/iptables
                systemctl enable --now iptables

                # Install SSM
                yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
                systemctl enable --now amazon-ssm-agent

                # Install kubectl
                KUBECTL_VERSION=v1.21.2
                curl -LO https://storage.googleapis.com/kubernetes-release/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl
                chmod +x ./kubectl
                mv ./kubectl /usr/bin/kubectl

                # Create kubectl config
                aws eks --region us-east-1 update-kubeconfig --name prod-midwest-mighty-crab --kubeconfig /opt/kube/config

                # Create the drain-node script
                mkdir -p /opt/scripts
                cat << 'EOF' > /opt/scripts/drain-node.sh
                #!/usr/bin/env bash

                trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM

                REQUESTED_INSTANCE_ID=${1:-none}
                remaining_heartbeat_events=${2:-3}

                INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
                if [[ $REQUESTED_INSTANCE_ID != $INSTANCE_ID ]]; then
                  echo "kubectl drain requested for $REQUESTED_INSTANCE_ID, not for $INSTANCE_ID. Exiting..."
                  exit 0
                fi

                set -eu

                K8S_NODE=$(curl -s http://169.254.169.254/latest/meta-data/hostname)
                REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//')
                ASG_NAME=$(aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=aws:autoscaling:groupName" --region ${REGION} | jq '.Tags[0].Value' -r)
                CMD_OPTS="--region ${REGION} --auto-scaling-group-name ${ASG_NAME} --lifecycle-hook-name prod-midwest-mighty-crab-worker-node-termination --instance-id ${INSTANCE_ID}"

                HEARTBEAT_TIMEOUT=$(aws autoscaling describe-lifecycle-hooks --region ${REGION} --auto-scaling-group-name ${ASG_NAME} --lifecycle-hook-names prod-midwest-mighty-crab-worker-node-termination | jq '.LifecycleHooks[0].HeartbeatTimeout')
                POLL_EVENTS_UNTIL_HEARTBEAT=$(( $HEARTBEAT_TIMEOUT / 10 - 3 ))

                echo "draining node: $K8S_NODE - $INSTANCE_ID"
                kubectl --kubeconfig='/opt/kube/config' drain --force --ignore-daemonsets --delete-local-data ${K8S_NODE} &
                PROC_ID=$!

                remaining_poll_events=$POLL_EVENTS_UNTIL_HEARTBEAT
                while kill -0 "$PROC_ID" &>/dev/null; do
                  ((remaining_poll_events--))

                  if (( $remaining_poll_events <= 0 )); then
                    if (( $remaining_heartbeat_events <= 0 )); then
                      aws autoscaling complete-lifecycle-action ${CMD_OPTS} --lifecycle-action-result ABORT
                      exit 1
                    else
                      aws autoscaling record-lifecycle-action-heartbeat ${CMD_OPTS}
                      ((remaining_heartbeat_events--))
                      remaining_poll_events=$POLL_EVENTS_UNTIL_HEARTBEAT
                    fi
                  fi

                  sleep 10
                done

                aws autoscaling complete-lifecycle-action ${CMD_OPTS} --lifecycle-action-result CONTINUE
                EOF

                chmod +x /opt/scripts/drain-node.sh

            EOT,
          + (known after apply),
        ]
        # (20 unchanged elements hidden)
    }

------------------------------------------------------------------------

This plan was saved to: tfplan

To perform exactly these actions, run the following command to apply:
    terraform apply "tfplan"
EOI

read -r -d '' TMP_INPUT <<'EOI'
[0m  [33m~[0m[0m resource "aws_iam_role" "ingress_controller" {
      [33m~[0m [0m[1m[0massume_role_policy[0m[0m    = jsonencode(
            {
              [31m-[0m [0mStatement = [
                  [31m-[0m [0m{
                      [31m-[0m [0mAction    = "sts:AssumeRoleWithWebIdentity"
                      [31m-[0m [0mCondition = {
                          [31m-[0m [0mStringLike = {
                              [31m-[0m [0moidc.eks.us-east-1.amazonaws.com/id/CF43514C002E188B59EA97EFA3E6282D:sub = "system:serviceaccount:terminus-system:*"
                            }
                        }
                      [31m-[0m [0mEffect    = "Allow"
                      [31m-[0m [0mPrincipal = {
                          [31m-[0m [0mFederated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/CF43514C002E188B59EA97EFA3E6282D"
                        }
                      [31m-[0m [0mSid       = ""
                    },
                ]
              [31m-[0m [0mVersion   = "2012-10-17"
            }

EOI

read -r -d '' TMP_INPUT_2 <<'EOI'
An execution plan has been generated and is shown below.
Resource actions are indicated with the following symbols:
  [32m+[0m create
  [33m~[0m update in-place
[32m+[0m/[31m-[0m create replacement and then destroy
 [36m<=[0m read (data resources)
[0m
Terraform will perform the following actions:

[1m  # aws_iam_instance_profile.karpenter[0][0m will be created[0m[0m
[0m  [32m+[0m[0m resource "aws_iam_instance_profile" "karpenter" {
      [32m+[0m [0m[1m[0marn[0m[0m         = (known after apply)
      [32m+[0m [0m[1m[0mcreate_date[0m[0m = (known after apply)
      [32m+[0m [0m[1m[0mid[0m[0m          = (known after apply)
      [32m+[0m [0m[1m[0mname[0m[0m        = "KarpenterNodeInstanceProfile-ninja-relaxing-baboon"
      [32m+[0m [0m[1m[0mpath[0m[0m        = "/"
      [32m+[0m [0m[1m[0mrole[0m[0m        = "ninja-relaxing-baboon20191021193910208300000006"
      [32m+[0m [0m[1m[0mtags_all[0m[0m    = (known after apply)
      [32m+[0m [0m[1m[0munique_id[0m[0m   = (known after apply)
    }

[1m  # aws_iam_role.external_dns[0][0m will be updated in-place[0m[0m
[0m  [33m~[0m[0m resource "aws_iam_role" "external_dns" {
      [33m~[0m [0m[1m[0massume_role_policy[0m[0m    = jsonencode(
            {
              [31m-[0m [0mStatement = [
                  [31m-[0m [0m{
                      [31m-[0m [0mAction    = "sts:AssumeRoleWithWebIdentity"
                      [31m-[0m [0mCondition = {
                          [31m-[0m [0mStringLike = {
                              [31m-[0m [0moidc.eks.us-east-1.amazonaws.com/id/0C0B19A5BF0FD097B5DB5796144ADC38:sub = "system:serviceaccount:terminus-system:*"
                            }
                        }
                      [31m-[0m [0mEffect    = "Allow"
                      [31m-[0m [0mPrincipal = {
                          [31m-[0m [0mFederated = "arn:aws:iam::***:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/0C0B19A5BF0FD097B5DB5796144ADC38"
                        }
                      [31m-[0m [0mSid       = ""
                    },
                ]
              [31m-[0m [0mVersion   = "2012-10-17"
            }
        ) [33m->[0m [0m(known after apply)
        [1m[0mid[0m[0m                    = "external-dns"
        [1m[0mname[0m[0m                  = "external-dns"
        [1m[0mtags[0m[0m                  = {
            "DeploymentName" = "EKS"
            "Environment"    = "Development"
            "ManagedBy"      = "https://github.com/GetTerminus/eks-infra"
            "ServiceName"    = "EKS"
            "Shared"         = "True"
            "Team"           = "SRE"
        }
        [90m# (9 unchanged attributes hidden)[0m[0m

        [90m# (1 unchanged block hidden)[0m[0m
    }
EOI

TMP_INPUT_BIG=$(<~/big_plan_no_timestamp.txt)

# sed is dumb on macos so use perl (yuck) locally
#INPUT=$(echo "$TMP_INPUT" | sed "s/\x1b\[31m-\x1b\[0m/😅/g")
#echo "$INPUT"
INPUT=$(echo "$RAW_INPUT" | perl -pe "s/(?<!\/)\e\[31m-\e\[0m/😅/g")
#debug "Input post-substitute: $INPUT"
INPUT=$(echo "$INPUT" | perl -pe 's/\x1b\[[0-9;]*m//g')
#debug "Input post-decolor: $INPUT"


# Read EXPAND_SUMMARY_DETAILS environment variable or use "true"
if [[ ${EXPAND_SUMMARY_DETAILS:-true} == "true" ]]; then
  DETAILS_STATE=" open"
else
  DETAILS_STATE=""
fi

# Read HIGHLIGHT_CHANGES environment variable or use "true"
COLOURISE=${HIGHLIGHT_CHANGES:-true}

ACCEPT_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GH_TOKEN"
CONTENT_HEADER="Content-Type: application/json"

PR_COMMENTS_URL="https://api.github.com/repos/GetTerminus/eks-observability-infra/issues/4/comments"
PR_COMMENT_URI="https://api.github.com/repos/GetTerminus/eks-observability-infra/issues/comments/4"
# curl -sSi -H "$AUTH_HEADER" -H "$ACCEPT_HEADER" -L $PR_COMMENTS_URL

WORKSPACE=ninja
POST_PLAN_OUTPUTS=true

execute_plan





exit 0


