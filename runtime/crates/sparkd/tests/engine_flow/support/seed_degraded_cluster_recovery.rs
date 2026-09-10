fn seed_degraded_cluster_recovery(harness: &Harness, owner_device_id: uuid::Uuid) -> String {
    let cluster_id = harness
        .state
        .cluster
        .as_ref()
        .expect("cluster service")
        .status()
        .expect("cluster status")
        .id
        .expect("cluster id");
    let local_node_id = harness.state.identity.node_id().to_string();
    let transaction_id = uuid::Uuid::new_v4().to_string();
    let launch_id = uuid::Uuid::new_v4().to_string();
    let now = sparkd::store::now_iso8601();
    let mut connection = harness.state.database.as_ref().expect("db").lock();
    let transaction = connection
        .transaction()
        .expect("recovery fixture transaction");
    let worker_node_id: String = transaction
        .query_row(
            "SELECT node_id FROM cluster_members
             WHERE cluster_id=?1 AND node_id!=?2",
            rusqlite::params![cluster_id, local_node_id],
            |row| row.get(0),
        )
        .expect("worker member");
    transaction
        .execute(
            "UPDATE cluster_state SET state='degraded',updated_at=?1 WHERE id=?2",
            rusqlite::params![now, cluster_id],
        )
        .expect("degrade cluster");
    transaction
        .execute(
            "UPDATE cluster_members SET reachable=0,qsfp_health='worker_lost'
             WHERE cluster_id=?1 AND node_id=?2",
            rusqlite::params![cluster_id, worker_node_id],
        )
        .expect("mark worker unavailable");
    transaction
        .execute(
            "INSERT INTO cluster_transactions
             (transaction_id,cluster_id,proposal_digest,coordinator_node_id,
              owner_device_id,local_address,peer_address,state,proposal_json,
              grant_json,created_at,updated_at)
             VALUES(?1,?2,?3,?4,?5,'172.31.252.1','172.31.252.2','ready','{}','{}',?6,?6)",
            rusqlite::params![
                transaction_id,
                cluster_id,
                "a".repeat(64),
                local_node_id,
                owner_device_id.to_string(),
                now,
            ],
        )
        .expect("ready transaction journal");
    transaction
        .execute(
            "INSERT INTO cluster_launches
             (launch_id,cluster_id,recipe_id,profile_id,execution_spec_json,state,
              coordinator_node_id,worker_node_id,failure_code,created_at,updated_at)
             VALUES(?1,?2,'example/model-32b','balanced-16k','{}','stopped',
                    ?3,?4,'WORKER_LOST',?5,?5)",
            rusqlite::params![launch_id, cluster_id, local_node_id, worker_node_id, now],
        )
        .expect("stopped distributed launch");
    transaction.commit().expect("commit recovery fixture");
    cluster_id
}
