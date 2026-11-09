%dw 2.0
output application/json
---
{
	code: vars.errorCode,
	message: "Request could not be processed",
	correlationId: correlationId
}
