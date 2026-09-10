use super::*;
use serde_json::{Value, json};

const NFT: &str = "/usr/sbin/nft";

pub(super) struct Policy {
    table: String,
    bridge: String,
}

impl Policy {
    fn from_network(network: &Value) -> Result<Self, BackendError> {
        let id = network["Id"]
            .as_str()
            .filter(|id| {
                id.len() == 64
                    && id
                        .bytes()
                        .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
            })
            .ok_or_else(|| {
                BackendError::Failure("inference network has no immutable identity".into())
            })?;
        let bridge = format!("br-{}", &id[..12]);
        if network["Options"]["com.docker.network.bridge.name"]
            .as_str()
            .is_some_and(|name| name != bridge)
        {
            return Err(BackendError::Failure(
                "inference network overrides its bridge interface".into(),
            ));
        }
        Ok(Self {
            table: format!("spi_{}", &id[..12]),
            bridge,
        })
    }

    fn marker(&self) -> String {
        format!("sparkpilot-inference-v1:{}", self.bridge)
    }

    fn script(&self) -> String {
        let Self { table, bridge } = self;
        format!(
            "add table inet {table} {{ comment \"{}\"; }}\n\
            add chain inet {table} input {{ type filter hook input priority -50; policy accept; }}\n\
            add chain inet {table} forward {{ type filter hook forward priority -50; policy accept; }}\n\
            add rule inet {table} input iifname \"{bridge}\" ct direction reply ct state established accept\n\
            add rule inet {table} input iifname \"{bridge}\" drop\n\
            add rule inet {table} forward iifname \"{bridge}\" drop\n",
            self.marker()
        )
    }

    // nft --numeric encodes conntrack reply as 1 and established as the state bit 2.
    fn entries(&self) -> Vec<Value> {
        let table = &self.table;
        let interface =
            json!({"match":{"op":"==","left":{"meta":{"key":"iifname"}},"right":self.bridge}});
        vec![
            json!({"table":{"family":"inet","name":table,"comment":self.marker()}}),
            json!({"chain":{"family":"inet","table":table,"name":"input","type":"filter","hook":"input","prio":-50,"policy":"accept"}}),
            json!({"chain":{"family":"inet","table":table,"name":"forward","type":"filter","hook":"forward","prio":-50,"policy":"accept"}}),
            json!({"rule":{"family":"inet","table":table,"chain":"input","expr":[interface.clone(),
                {"match":{"op":"==","left":{"ct":{"key":"direction"}},"right":1}},
                {"match":{"op":"in","left":{"ct":{"key":"state"}},"right":2}}, {"accept":null}]}}),
            json!({"rule":{"family":"inet","table":table,"chain":"input","expr":[interface.clone(),{"drop":null}]}}),
            json!({"rule":{"family":"inet","table":table,"chain":"forward","expr":[interface,{"drop":null}]}}),
        ]
    }

    fn matches(&self, evidence: &Value) -> bool {
        let Some(entries) = evidence.get("nftables").and_then(Value::as_array) else {
            return false;
        };
        let mut actual = Vec::new();
        for entry in entries {
            if entry.get("metainfo").is_some() {
                continue;
            }
            let mut entry = entry.clone();
            let Some(object) = entry.as_object_mut().filter(|o| o.len() == 1) else {
                return false;
            };
            let Some(fields) = object.values_mut().next().and_then(Value::as_object_mut) else {
                return false;
            };
            fields.remove("handle");
            actual.push(entry);
        }
        actual == self.entries()
    }

    fn inspect(&self, backend: &DockerBackend) -> Result<Option<Value>, BackendError> {
        let output = backend.run_appliance(
            NFT,
            vec![
                "--json".into(),
                "--numeric".into(),
                "list".into(),
                "table".into(),
                "inet".into(),
                self.table.clone(),
            ],
            None,
        )?;
        if !output.success() {
            if output.stderr_text().contains("No such file or directory") {
                return Ok(None);
            }
            return Err(BackendError::Failure(
                "cannot verify inference firewall".into(),
            ));
        }
        serde_json::from_slice(&output.stdout)
            .map(Some)
            .map_err(|_| BackendError::Failure("invalid inference firewall evidence".into()))
    }
}

pub(super) fn ensure(backend: &DockerBackend, network: &Value) -> Result<(), BackendError> {
    let policy = Policy::from_network(network)?;
    match policy.inspect(backend)? {
        Some(evidence) if policy.matches(&evidence) => return Ok(()),
        Some(_) => {
            return Err(BackendError::Failure(
                "inference firewall is foreign or modified; refusing model launch".into(),
            ));
        }
        None => {}
    }
    let output = backend.run_appliance(
        NFT,
        vec!["--file".into(), "-".into()],
        Some(&policy.script()),
    )?;
    if !output.success() || !policy.inspect(backend)?.is_some_and(|e| policy.matches(&e)) {
        return Err(BackendError::Failure(
            "inference firewall installation could not be verified".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests;

#[cfg(test)]
pub(super) fn test_evidence() -> Value {
    let policy = Policy::from_network(&json!({"Id":"a".repeat(64),"Options":{}})).unwrap();
    json!({"nftables":policy.entries()})
}

impl DockerBackend {
    /// Reinstall the kernel boundary before the runtime can serve requests after a reboot.
    pub fn reconcile_inference_firewall(&self) -> Result<(), BackendError> {
        if !self.plan_only
            && let Some(network) = self.inference_network().inference_network_inspect()?
        {
            validate_inference_network(&network)?;
            ensure(self, &network)?;
            migration::stop_legacy(self, &network)?;
        }
        Ok(())
    }
}

mod migration;
