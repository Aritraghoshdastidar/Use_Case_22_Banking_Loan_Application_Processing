SELECT rule_code, rule_type, input_value, weight, points, contribution, triggered
FROM decision_rule_hits
WHERE application_id = :applicationId
ORDER BY id
