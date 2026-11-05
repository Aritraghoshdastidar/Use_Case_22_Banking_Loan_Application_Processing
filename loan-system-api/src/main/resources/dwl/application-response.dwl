%dw 2.0
output application/json
var a = vars.app[0]
var d = vars.decision[0]
---
// Builds the full application view from the four query results kept in variables.
// This is an internal system-API view: the experience API decides what to expose to callers.
{
    applicationId: a.application_id,
    requestId: a.request_id,
    correlationId: a.correlation_id,
    productCode: a.product_code,
    requestedAmount: a.requested_amount,
    requestedTenure: a.requested_tenure,
    applicantName: a.applicant_name,
    dateOfBirth: a.date_of_birth,
    identityRef: a.identity_ref,
    email: a.email,
    monthlyIncome: a.monthly_income,
    monthlyObligations: a.monthly_obligations,
    employmentMonths: a.employment_months,
    manifest: read(a.manifest, "application/json"),
    stage: a.stage,
    stageReason: a.stage_reason,
    verificationRound: a.verification_round,
    createdAt: a.created_at,
    updatedAt: a.updated_at,
    documents: vars.docs map (doc) -> {
        docType: doc.doc_type,
        fileName: doc.file_name,
        status: doc.status,
        reason: doc.reason,
        sizeBytes: doc.size_bytes,
        sha256: doc.sha256,
        sourcePath: doc.source_path,
        storedPath: doc.stored_path
    },
    decision: if (d != null) {
        decision: d.decision,
        score: d.score,
        scorecardVersion: d.scorecard_version,
        decidingRule: d.deciding_rule,
        reasonCodes: if (isEmpty(d.reason_codes)) [] else (d.reason_codes splitBy ","),
        requestedAmount: d.requested_amount,
        approvedAmount: d.approved_amount,
        approvedTenure: d.approved_tenure,
        approvedRatePct: d.approved_rate_pct,
        instalment: d.instalment,
        affordabilityRatio: d.affordability_ratio,
        reductionReason: d.reduction_reason,
        offerExpiresAt: d.offer_expires_at,
        decidedAt: d.decided_at,
        ruleHits: vars.hits map (h) -> {
            ruleCode: h.rule_code,
            ruleType: h.rule_type,
            inputValue: h.input_value,
            weight: h.weight,
            points: h.points,
            contribution: h.contribution,
            triggered: h.triggered
        }
    } else null
}
