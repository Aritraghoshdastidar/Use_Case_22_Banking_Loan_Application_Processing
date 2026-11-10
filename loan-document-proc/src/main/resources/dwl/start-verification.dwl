%dw 2.0
output application/json
---
{
	toStage: "VERIFYING",
	reason: "Document verification started",
	sourceApp: p('app.name'),
	correlationId: vars.app.correlationId,
	expectedFromStage: "RECEIVED"
}
