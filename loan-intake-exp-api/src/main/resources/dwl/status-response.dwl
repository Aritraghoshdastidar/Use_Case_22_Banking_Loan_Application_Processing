%dw 2.0
output application/json
---
{
	applicationId: payload.applicationId,
	stage: payload.stage,
	reason: payload.stageReason,
	documents: payload.documents map (d) -> {
		docType: d.docType,
		fileName: d.fileName,
		status: d.status,
		reason: d.reason
	},
	decision: if (payload.decision != null) {
		decision: payload.decision.decision,
		reasonCodes: payload.decision.reasonCodes,
		approvedAmount: payload.decision.approvedAmount,
		approvedTenure: payload.decision.approvedTenure,
		approvedRatePct: payload.decision.approvedRatePct,
		instalment: payload.decision.instalment,
		reductionReason: payload.decision.reductionReason,
		offerExpiresAt: payload.decision.offerExpiresAt
	} else null
}
