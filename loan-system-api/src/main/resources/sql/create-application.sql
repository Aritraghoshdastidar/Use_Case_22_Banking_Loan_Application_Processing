WITH ins AS (
    INSERT INTO applications (request_id, payload_hash, correlation_id, product_code, requested_amount, requested_tenure,
                              applicant_name, date_of_birth, identity_ref, email, monthly_income, monthly_obligations,
                              employment_months, manifest)
    VALUES (:requestId, :payloadHash, CAST(:correlationId AS uuid), :productCode, :requestedAmount, :requestedTenure,
            :applicantName, CAST(:dateOfBirth AS date), :identityRef, :email, :monthlyIncome, :monthlyObligations,
            :employmentMonths, CAST(:manifest AS jsonb))
    ON CONFLICT (request_id) DO NOTHING
    RETURNING application_id, correlation_id
),
ob AS (
    INSERT INTO outbox (id, queue_name, payload)
    SELECT CAST(:messageId AS uuid), 'loan.verify.q',
           jsonb_build_object('messageId', CAST(:messageId AS text),
                              'correlationId', CAST(ins.correlation_id AS text),
                              'applicationId', ins.application_id,
                              'type', 'VERIFY_REQUESTED',
                              'attempt', 1,
                              'createdAt', CAST(:createdAt AS text))
    FROM ins
),
au AS (
    INSERT INTO decision_audit (application_id, correlation_id, event, to_stage, source_app)
    SELECT ins.application_id, ins.correlation_id, 'RECEIVED', 'RECEIVED', 'loan-system-api'
    FROM ins
)
SELECT application_id FROM ins
