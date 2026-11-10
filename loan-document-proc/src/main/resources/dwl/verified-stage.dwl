%dw 2.0
output application/json
---
{
	toStage: "VERIFIED",
	reason: "All required documents verified",
	sourceApp: p('app.name'),
	correlationId: vars.app.correlationId,
	expectedFromStage: "VERIFYING",
	detail: {
		round: vars.app.verificationRound,
		accepted: sizeOf(vars.validation.accepted),
		folder: p('store.verifiedPrefix') ++ vars.app.applicationId ++ "/",
		unexpectedCount: sizeOf(vars.reconciliation.unexpected)
	},
	publish: {
		queue: "loan.score.q",
		"type": "SCORE_REQUESTED"
	}
}
