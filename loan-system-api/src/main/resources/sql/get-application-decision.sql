SELECT decision, score, scorecard_version, deciding_rule, array_to_string(reason_codes, ',') AS reason_codes,
       requested_amount, approved_amount, approved_tenure, approved_rate_pct, instalment,
       affordability_ratio, reduction_reason, offer_expires_at, decided_at
FROM credit_decisions
WHERE application_id = :applicationId
