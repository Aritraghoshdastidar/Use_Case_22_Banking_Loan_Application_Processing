%dw 2.0
output application/json
---
{
	toStage: "SCORING",
	reason: "Scoring started",
	sourceApp: p('app.name'),
	correlationId: vars.app.correlationId,
	expectedFromStage: "VERIFIED"
}
