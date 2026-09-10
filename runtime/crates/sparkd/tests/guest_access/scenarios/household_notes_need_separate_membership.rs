// These exercise the real signed-request middleware, presence proof, database transaction and replay store.
const HOUSEHOLD_NOTES: &str = "/api/v1/household/notes";
const HOUSEHOLD_MEMBERS: &str = "/api/v1/household/members";

async fn household_response(household: &Household, request: Request<axum::body::Body>) -> (StatusCode, Value) {
    let response = router(household.state.clone()).oneshot(request).await.unwrap();
    let status = response.status();
    let bytes = to_bytes(response.into_body(), 8 << 20).await.unwrap();
    (status, serde_json::from_slice(&bytes).unwrap_or(Value::Null))
}

async fn join_household_with_presence(household: &Household) {
    household.clock.set(time::OffsetDateTime::now_utc());
    let presence = fresh_key();
    let spki = presence.verifying_key().to_public_key_der().unwrap();
    {
        let db = household.state.database.as_ref().unwrap().lock();
        db.execute("UPDATE devices SET presence_public_key_spki=?1,presence_public_key_fingerprint=?2 WHERE id=?3",
            rusqlite::params![spki.as_bytes(),sha256_hex(spki.as_bytes()),household.owner.device_id.to_string()]).unwrap();
    }
    let bytes = serde_json::to_vec(&json!({"device_id":household.guest.device_id,"joined":true})).unwrap();
    let mut request = signed(household,&household.owner,Method::POST,HOUSEHOLD_MEMBERS,&bytes);
    let expires_at = (time::OffsetDateTime::now_utc()+time::Duration::seconds(30)).format(&time::format_description::well_known::Rfc3339).unwrap();
    let header = |name: &str| request.headers().get(name).unwrap().to_str().unwrap();
    let canonical = spark_contracts::user_presence_canonical("POST",HOUSEHOLD_MEMBERS,
        header(auth::HEADER_TIMESTAMP),header(auth::HEADER_NONCE),header(auth::HEADER_CONTENT_SHA256),
        &household.owner.device_id,&expires_at,&SIGNING_NODE_ID);
    let signature: p256::ecdsa::Signature = presence.sign(canonical.as_bytes());
    let proof = spark_contracts::UserPresenceHeader {version:spark_contracts::USER_PRESENCE_PROOF_VERSION,expires_at,signature:base64url_encode(&signature.to_bytes())};
    request.headers_mut().insert(sparkd::user_presence::HEADER_USER_PRESENCE,
        HeaderValue::from_str(&base64url_encode(&serde_json::to_vec(&proof).unwrap())).unwrap());
    let (status,body) = household_response(household,request).await;
    assert_eq!(status,StatusCode::OK,"{body}");
}

#[tokio::test]
async fn household_requires_explicit_membership_and_rechecks_paused_guests() {
    let household = household(&evening_policy());
    let (status,body) = send(&household,&household.guest,Method::GET,HOUSEHOLD_NOTES,Value::Null).await;
    assert_eq!(status,StatusCode::FORBIDDEN);
    assert_eq!(error_code(&body),"HOUSEHOLD_ACCESS_REQUIRED");
    let (status,body) = send(&household,&household.owner,Method::POST,HOUSEHOLD_MEMBERS,
        json!({"device_id":household.guest.device_id,"joined":true})).await;
    assert_eq!(status,StatusCode::FORBIDDEN);
    assert_eq!(error_code(&body),"USER_PRESENCE_REQUIRED");
    join_household_with_presence(&household).await;
    let (status,_) = send(&household,&household.guest,Method::GET,HOUSEHOLD_NOTES,Value::Null).await;
    assert_eq!(status,StatusCode::OK);
    let (status,_) = send(&household,&household.guest,Method::POST,HOUSEHOLD_MEMBERS,
        json!({"device_id":household.owner.device_id,"joined":false})).await;
    assert_eq!(status,StatusCode::FORBIDDEN);
    set_state(&household,GrantState::Paused);
    let (status,body) = send(&household,&household.guest,Method::GET,HOUSEHOLD_NOTES,Value::Null).await;
    assert_eq!(status,StatusCode::FORBIDDEN,"{body}");
}

#[tokio::test]
async fn household_replay_never_copies_note_text_and_deletion_cannot_be_undone_by_retry() {
    let household = household(&evening_policy());
    join_household_with_presence(&household).await;
    let note_id = uuid::Uuid::new_v4();
    let private_text = "A deliberately shared household detail";
    let key = uuid::Uuid::new_v4().to_string();
    let bytes = serde_json::to_vec(&json!({"id":note_id,"expected_revision":0,"title":"Plan","body":private_text,"delete":false})).unwrap();
    for _ in 0..2 {
        let mut request = signed(&household,&household.guest,Method::POST,HOUSEHOLD_NOTES,&bytes);
        request.headers_mut().insert("idempotency-key",HeaderValue::from_str(&key).unwrap());
        let (status,body)=household_response(&household,request).await;
        assert_eq!(status,StatusCode::OK,"{body}");
        assert_eq!(body["revision"],1);
        assert!(!body.to_string().contains(private_text));
    }
    let (status,snapshot) = send(&household,&household.owner,Method::GET,HOUSEHOLD_NOTES,Value::Null).await;
    assert_eq!(status,StatusCode::OK);
    assert_eq!(snapshot["notes"].as_array().unwrap().len(),1);
    assert_eq!(snapshot["notes"][0]["body"],private_text);
    let (status,_) = send(&household,&household.guest,Method::POST,HOUSEHOLD_NOTES,
        json!({"id":note_id,"expected_revision":1,"title":"","body":"","delete":true})).await;
    assert_eq!(status,StatusCode::OK);
    let mut retry = signed(&household,&household.guest,Method::POST,HOUSEHOLD_NOTES,&bytes);
    retry.headers_mut().insert("idempotency-key",HeaderValue::from_str(&key).unwrap());
    let (status,_) = household_response(&household,retry).await;
    assert_eq!(status,StatusCode::OK);
    let (_,snapshot) = send(&household,&household.owner,Method::GET,HOUSEHOLD_NOTES,Value::Null).await;
    assert!(snapshot["notes"].as_array().unwrap().is_empty());
    let db = household.state.database.as_ref().unwrap().lock();
    let stored_text: String=db.query_row("SELECT body FROM household_notes WHERE id=?1",[note_id.to_string()],|r|r.get(0)).unwrap();
    assert!(stored_text.is_empty());
    let audit_text: String=db.query_row("SELECT group_concat(details_json) FROM audit_records WHERE action LIKE 'household.%'",[],|r|r.get(0)).unwrap();
    assert!(!audit_text.contains(private_text));
}
