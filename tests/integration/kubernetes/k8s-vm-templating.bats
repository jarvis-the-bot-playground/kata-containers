#!/usr/bin/env bats
#
# Copyright (c) 2024 Kata Containers
#
# SPDX-License-Identifier: Apache-2.0
#
# Tests for Kata VM templating (factory) functionality in Kubernetes integration mode

load "${BATS_TEST_DIRNAME}/lib.sh"
load "${BATS_TEST_DIRNAME}/../../common.bash"
load "${BATS_TEST_DIRNAME}/confidential_common.sh"
load "${BATS_TEST_DIRNAME}/tests_common.sh"

setup() {
	if [[ "${KATA_HYPERVISOR}" != "clh" && "${KATA_HYPERVISOR}" != "qemu" ]] || is_confidential_runtime_class; then
		skip "VM templating is only supported for non-confidential clh/qemu hypervisors"
	fi

	# VM templating uses shared_fs="none", which requires a block-device-based
	# snapshotter (blockfile or erofs).
	case "${SNAPSHOTTER:-}" in
		blockfile|erofs) ;;
		*) skip "VM templating requires blockfile/erofs snapshotter (SNAPSHOTTER=${SNAPSHOTTER:-unset})" ;;
	esac

	setup_common || die "setup_common failed"

	# Build a Kata runtime config drop-in that enables VM templating and
	# disables shared_fs (incompatible with templating).
	local runtime_config_dropin_file="${BATS_TEST_TMPDIR}/99-k8s-vm-templating.toml"
	cat > "${runtime_config_dropin_file}" <<DROPIN
[hypervisor.${KATA_HYPERVISOR}]
shared_fs = "none"
default_vcpus = 1
default_memory = 512

[factory]
enable_template = true
template_path = "/run/vc/vm/template"
DROPIN

	# Install the drop-in on the node selected by setup_common and record
	# the remote path so teardown can remove it.
	dropin_path="$(set_kata_runtime_config_dropin_file "$node" "${runtime_config_dropin_file}")" \
		|| die "Failed to install Kata runtime config drop-in on node $node"

	# Initialize the VM template on the target node.
	exec_host "$node" "sudo kata-runtime factory init" \
		|| die "Failed to initialize VM template on node $node"
}

@test "VM template factory is initialized" {
	exec_host "$node" "test -d /run/vc/vm/template" \
		|| die "VM template directory not found on $node"
}

@test "Pod can be created with templated VM" {
	pod_name="test-templated-pod"
	ctr_name="test-container"

	pod_config=$(mktemp --tmpdir pod_config.XXXXXX.yaml)
	cp "$pod_config_dir/busybox-template.yaml" "$pod_config"

	sed -i "s/POD_NAME/$pod_name/" "$pod_config"
	sed -i "s/CTR_NAME/$ctr_name/" "$pod_config"

	kubectl create -f "${pod_config}"
	kubectl wait --for=condition=Ready --timeout=120s "pod/${pod_name}" || die "Pod failed to reach Ready state"

	kubectl get pod "${pod_name}" | grep Running || die "Pod is not in Running state"

	kubectl exec "${pod_name}" -- sh -c "echo 'Hello from templated VM' && exit 0"
}

teardown() {
	if [[ "${KATA_HYPERVISOR}" != "clh" && "${KATA_HYPERVISOR}" != "qemu" ]] \
		|| is_confidential_runtime_class \
		|| ! [[ "${SNAPSHOTTER:-}" =~ ^(blockfile|erofs)$ ]]; then
		return 0
	fi

	# Best-effort cleanup of any pod/yaml created by a test in this file.
	kubectl delete pod test-templated-pod --ignore-not-found=true --wait=false || true
	[[ -n "${pod_config:-}" && -f "${pod_config}" ]] && rm -f "${pod_config}"

	# Destroy the VM template and remove the config drop-in on the target node.
	exec_host "$node" "sudo kata-runtime factory destroy" \
		|| echo "Warning: Failed to destroy VM template on node $node"

	if [[ -n "${dropin_path:-}" ]]; then
		remove_kata_runtime_config_dropin_file "$node" "${dropin_path}" \
			|| echo "Warning: Failed to remove Kata runtime config drop-in on node $node"
	fi

	teardown_common "${node:-}" "${node_start_time:-}"
}
