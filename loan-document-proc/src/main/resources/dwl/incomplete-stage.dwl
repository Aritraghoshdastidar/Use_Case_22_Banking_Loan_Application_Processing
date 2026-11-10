%dw 2.0
output application/json
---
{
	toStage: "DOCUMENTS_INCOMPLETE",
	reason: vars.incompleteReason,
	sourceApp: p('app.name'),
	correlationId: vars.app.correlationId,
	expectedFromStage: "VERIFYING",
	detail: {
		reason: vars.incompleteReason,
		folder: vars.app.manifest.folder,
		round: vars.app.verificationRound,
		missing: vars.validation.missingTypes,
		missingFiles: vars.reconciliation.missingFiles,
		quarantined: vars.validation.quarantined map ((q) -> {fileName: q.fileName, docType: q.docType, reason: q.reason}),
		duplicates: vars.validation.duplicates map ((d) -> {fileName: d.fileName, docType: d.docType}),
		unexpectedCount: sizeOf(vars.reconciliation.unexpected),
		(mismatch: vars.manifestCheck) if vars.manifestCheck != null
	},
	publish: {
		queue: "loan.decision.q",
		"type": "DECISION_READY"
	}
}
