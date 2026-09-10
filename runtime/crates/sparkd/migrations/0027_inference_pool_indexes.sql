CREATE INDEX inference_reservation_capacity ON inference_reservations(state, deployment_id);
CREATE INDEX inference_reservation_router ON inference_reservations(router_device_id, updated_at);
CREATE INDEX inference_reservation_grant ON inference_reservations(grant_id, state);
CREATE INDEX inference_pool_preview_expiry ON inference_pool_previews(expires_at);
CREATE INDEX inference_pool_mutation_retention ON inference_pool_mutations(created_at);
