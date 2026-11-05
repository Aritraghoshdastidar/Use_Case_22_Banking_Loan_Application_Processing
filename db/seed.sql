-- Seed data. Numbers frozen from the team plan appendix (accepted in Phase 0).
-- Re-runnable: ON CONFLICT DO NOTHING.

INSERT INTO products (code, name, min_amount, max_amount, min_tenure_months, max_tenure_months,
                      annual_rate_pct, min_age_at_application, max_age_at_application,
                      max_age_at_maturity, emi_ceiling_pct, amount_step) VALUES
 ('PL', 'Personal loan',   50000,  1000000,  6,  60, 12.00, 21, 60, 65, 50.00, 1000),
 ('HL', 'Home loan',      500000, 10000000, 60, 240,  9.00, 21, 60, 70, 50.00, 1000)
ON CONFLICT DO NOTHING;

-- Checklist. Payslips: 2 required (scenario 8 "one payslip where two are required"). Payslip limit 2 MB, others 5 MB.
INSERT INTO product_document_rules (product_code, doc_type, description, required_count, max_size_bytes, allowed_extensions, allowed_mime_types) VALUES
 ('PL','ID_PROOF',       'Government photo identity document', 1, 5242880, '{pdf,jpg,jpeg,png}', '{application/pdf,image/jpeg,image/png}'),
 ('PL','ADDRESS_PROOF',  'Proof of current address',           1, 5242880, '{pdf,jpg,jpeg,png}', '{application/pdf,image/jpeg,image/png}'),
 ('PL','PAYSLIP',        'Recent payslip',                     2, 2097152, '{pdf}',              '{application/pdf}'),
 ('HL','ID_PROOF',       'Government photo identity document', 1, 5242880, '{pdf,jpg,jpeg,png}', '{application/pdf,image/jpeg,image/png}'),
 ('HL','ADDRESS_PROOF',  'Proof of current address',           1, 5242880, '{pdf,jpg,jpeg,png}', '{application/pdf,image/jpeg,image/png}'),
 ('HL','PAYSLIP',        'Recent payslip',                     2, 2097152, '{pdf}',              '{application/pdf}'),
 ('HL','PROPERTY_DOCUMENT','Property sale agreement or title document', 1, 5242880, '{pdf}',      '{application/pdf}')
ON CONFLICT DO NOTHING;

-- Scorecard SC-1.0: weights sum to 100. Bands: >=70 APPROVED, 50..<70 REFERRED, <50 DECLINED. Offers valid 30 days.
INSERT INTO scorecard_versions (version, approve_min_score, refer_min_score, offer_validity_days, active) VALUES
 ('SC-1.0', 70, 50, 30, TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO scorecard_config (version, factor, weight, zero_points_at, full_points_at) VALUES
 ('SC-1.0','BUREAU_SCORE',        35, 600, 750),    -- <=600 -> 0, >=750 -> 100
 ('SC-1.0','DEBT_TO_INCOME',      20, 0.60, 0.30),  -- >=60% -> 0, <=30% -> 100 (lower is better)
 ('SC-1.0','LOAN_TO_INCOME',      15, 5, 1),        -- >=5x annual income -> 0, <=1x -> 100
 ('SC-1.0','EMPLOYMENT_STABILITY',15, 6, 36),       -- <=6 months -> 0, >=36 -> 100
 ('SC-1.0','REPAYMENT_HISTORY',   15, 3, 0)         -- 3+ missed in 24m -> 0, none -> 100
ON CONFLICT DO NOTHING;

-- Demo applicants used by the bureau mock. Identity format: 5 letters, 4 digits, 1 letter.
-- ABCDE1234F strong score         -> APPROVED path
-- FGHIJ5678K middling score       -> REFERRED path
-- LMNOP9012Q weak score           -> DECLINED path
-- RSTUV3456W high score + default -> HP-02 decline (scenario 19)
-- Any other identity has no history -> DATA_UNAVAILABLE -> REFERRED
INSERT INTO applicant_history (identity_ref, bureau_score, missed_payments_24m, active_default) VALUES
 ('ABCDE1234F', 780, 0, FALSE),
 ('FGHIJ5678K', 665, 1, FALSE),
 ('LMNOP9012Q', 540, 3, FALSE),
 ('RSTUV3456W', 790, 0, TRUE)
ON CONFLICT DO NOTHING;

INSERT INTO system_flags (flag_key, flag_value) VALUES
 ('bureau_enabled', 'true')
ON CONFLICT DO NOTHING;
