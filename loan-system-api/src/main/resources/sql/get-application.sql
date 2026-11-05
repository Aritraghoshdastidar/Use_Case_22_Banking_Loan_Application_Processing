SELECT application_id, request_id, CAST(correlation_id AS text) AS correlation_id, product_code,
       requested_amount, requested_tenure, applicant_name, CAST(date_of_birth AS text) AS date_of_birth,
       identity_ref, email, monthly_income, monthly_obligations, employment_months,
       CAST(manifest AS text) AS manifest, stage, stage_reason, verification_round, created_at, updated_at
FROM applications
WHERE application_id = :applicationId
