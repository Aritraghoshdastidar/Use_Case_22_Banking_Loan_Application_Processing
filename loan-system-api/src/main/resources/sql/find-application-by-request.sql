SELECT application_id, payload_hash, stage
FROM applications
WHERE request_id = :requestId
