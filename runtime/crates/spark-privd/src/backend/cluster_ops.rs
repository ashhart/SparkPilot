use std::collections::{HashMap, HashSet};

use std::fs;

use std::io::{Read, Write};

use std::net::Ipv4Addr;

use std::net::{SocketAddr, TcpStream};

use std::time::Duration;

use crate::protocol::{
    ClusterExecutionDigestInput, ClusterLinkPhase, PrivilegedOperation, PrivilegedResponse,
    cluster_execution_digest, valid_pinned_image, valid_profile_id, valid_recipe_id,
};

use sha2::{Digest, Sha256};

use super::{ARPING_BIN, BackendError, DockerBackend, NMCLI_BIN, valid_served_name};

const CLUSTER_LINK_MTU: &str = "9000";

const CLUSTER_LINK_PREFIX: &str = "SparkPilot-CX7";

const CONNECTX_VENDOR: &str = "0x15b3";

const IP_BIN: &str = "/usr/sbin/ip";

const NFT_BIN: &str = "/usr/sbin/nft";

const TIMEOUT_BIN: &str = "/usr/bin/timeout";

const TWO_RANK_TIMEOUT: &str = "180s";

const TWO_RANK_KILL_AFTER: &str = "10s";

const CLUSTER_LINK_WAIT_SECONDS: &str = "90";

const CLUSTER_OWNER: &str = "sparkpilot-cluster-v1";

const CLUSTER_PROBE_OWNER: &str = "sparkpilot-cluster-probe-v1";

const RAY_WAIT_ATTEMPTS: &str = "60";

const RAY_PROBE_ATTEMPTS: &str = "1";

const CLUSTER_TCP_PORTS: &str =
    "6379, 8265, 10001-10003, 11000-11063, 18100-18199, 19443, 24000-65535";

const CLUSTER_UDP_PORTS: &str = "24000-65535";

const MIN_CLUSTER_BANDWIDTH_MBPS: u64 = 10_000;

const MAX_CLUSTER_LATENCY_US: u64 = 5_000;

const TWO_RANK_COLLECTIVE_SCRIPT: &str = "import statistics,time,torch\nimport torch.distributed as d\nd.init_process_group('nccl')\nx=torch.tensor([d.get_rank()+1],device='cuda')\nd.all_reduce(x)\nassert int(x.item())==3\nlat=[]\nfor _ in range(20):\n torch.cuda.synchronize();t=time.perf_counter();d.barrier();torch.cuda.synchronize();lat.append((time.perf_counter()-t)*1000000)\npayload=torch.ones(16777216,device='cuda',dtype=torch.float32)\nd.all_reduce(payload);torch.cuda.synchronize();t=time.perf_counter()\nfor _ in range(5): d.all_reduce(payload)\ntorch.cuda.synchronize();elapsed=time.perf_counter()-t\nlatency_us=int(statistics.median(lat))\nbandwidth_mbps=int((payload.numel()*payload.element_size()*8*5)/(elapsed*1000000))\nprint(f'SPARK_TWO_RANK_METRICS latency_us={latency_us} bandwidth_mbps={bandwidth_mbps}')\nprint('SPARK_TWO_RANK_OK')\nd.destroy_process_group()";

const CLUSTER_LIVENESS_SCRIPT: &str = "import sys,time\nimport ray\nattempts=int(sys.argv[1])\nexpected_nodes=set(sys.argv[2:4])\nexpected_execution=sys.argv[4]\nray.init(address='auto',logging_level='ERROR')\nfor attempt in range(attempts):\n alive=[node for node in ray.nodes() if node.get('Alive')]\n node_keys={key for node in alive for key,value in node.get('Resources',{}).items() if key.startswith('spark_node_') and value>=1}\n execution_keys={key for node in alive for key,value in node.get('Resources',{}).items() if key.startswith('spark_execution_') and value>=1}\n once_each=all(sum(1 for node in alive if node.get('Resources',{}).get(key,0)>=1)==1 for key in expected_nodes)\n execution_each=all(node.get('Resources',{}).get(expected_execution,0)>=1 for node in alive)\n if len(alive)==2 and node_keys==expected_nodes and once_each and execution_keys=={expected_execution} and execution_each:\n  print('SPARK_CLUSTER_EXPECTED_2')\n  raise SystemExit(0)\n if attempt+1<attempts: time.sleep(0.5)\nprint('SPARK_CLUSTER_IDENTITY_MISMATCH')\nraise SystemExit(3)";

const WORKER_WAIT_SCRIPT: &str = "import os,socket,sys,time\nhost,local,resources=sys.argv[1:4]\nfor _ in range(360):\n try:\n  with socket.create_connection((host,6379),0.5): pass\n  os.execvp('ray',['ray','start',f'--address={host}:6379',f'--node-ip-address={local}',f'--resources={resources}','--node-manager-port=10002','--object-manager-port=10003','--min-worker-port=11000','--max-worker-port=11063','--block'])\n except OSError: time.sleep(0.5)\nraise SystemExit(4)";

fn valid_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn bounded_detail(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).chars().take(2_000).collect()
}

pub(super) fn execute(
    backend: &DockerBackend,
    op: &PrivilegedOperation,
) -> Result<PrivilegedResponse, BackendError> {
    let request_id = op.request_id();
    match op {
        PrivilegedOperation::ConfigureClusterLink {
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
            phase,
            ..
        } => configure_link(
            backend,
            request_id,
            *transaction_id,
            *cluster_id,
            *local_node_id,
            *peer_node_id,
            *local_address,
            *peer_address,
            *phase,
        ),
        PrivilegedOperation::ProbeClusterLink {
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
            ..
        } => probe_link(
            backend,
            request_id,
            *transaction_id,
            *cluster_id,
            *local_node_id,
            *peer_node_id,
            *local_address,
            *peer_address,
        ),
        PrivilegedOperation::RunClusterCollectiveTest { image_digest, .. } => {
            run_collective(backend, request_id, image_digest)
        }
        PrivilegedOperation::RunClusterTwoRankTest {
            transaction_id,
            cluster_id,
            local_node_id,
            peer_node_id,
            local_address,
            peer_address,
            coordinator_address,
            node_rank,
            image_digest,
            ..
        } => run_two_rank(
            backend,
            request_id,
            *transaction_id,
            *cluster_id,
            *local_node_id,
            *peer_node_id,
            *local_address,
            *peer_address,
            *coordinator_address,
            *node_rank,
            image_digest,
        ),
        PrivilegedOperation::StartClusterLaunch { .. } => {
            let spec = ClusterLaunchSpec::from_operation(backend, op)?;
            start_launch(backend, request_id, spec)
        }
        PrivilegedOperation::ProbeClusterLaunch {
            cluster_id,
            launch_id,
            local_node_id,
            peer_node_id,
            ..
        } => probe_launch(
            backend,
            request_id,
            *cluster_id,
            *launch_id,
            *local_node_id,
            *peer_node_id,
        ),
        PrivilegedOperation::StopClusterLaunch {
            cluster_id,
            launch_id,
            ..
        } => stop_launch(backend, request_id, *cluster_id, *launch_id),
        _ => unreachable!("non-cluster operation sent to the cluster backend"),
    }
}

#[cfg(test)]
#[path = "cluster_ops/tests.rs"]
mod tests;

mod collective;
use collective::{run_collective, run_two_rank};

mod link_discovery;
use link_discovery::{
    cluster_link_owner_marker, cluster_link_profile, connectx_interface, inspect_cluster_profile,
    profile_matches, valid_interface_name, valid_mac_address,
};

mod firewall_policy;
use firewall_policy::{
    cluster_firewall_evidence, cluster_firewall_owner_marker, cluster_firewall_table,
    exact_cluster_firewall_policy, exact_table_marker, firewall_install_script,
};

mod firewall;
use firewall::{
    cleanup_cluster_firewall, cleanup_cluster_firewall_without_profile, install_cluster_firewall,
    require_cluster_firewall,
};

mod link_configuration;
use link_configuration::configure_link;

mod link_qualification;
use link_qualification::{probe_link, qualify_owned_cluster_link};

mod containers;
use containers::{
    ContainerEvidence, append_labels, ensure_container, inspect_container, remove_container,
    require_exact_container,
};

mod launch_spec;
use launch_spec::ClusterLaunchSpec;
pub(super) use launch_spec::validate_start_operation;

mod launch_plan;
use launch_plan::{engine_argv, launch_names, membership_argv, ray_member_argv};

mod launch_lifecycle;
use launch_lifecycle::{probe_launch, start_launch, stop_launch};
